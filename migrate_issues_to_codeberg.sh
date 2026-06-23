#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
LOG_FILE="$SCRIPT_DIR/migrate_issues_$(date '+%Y%m%d_%H%M%S').log"

log() {
    local level="$1" msg="$2"
    local line="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $msg"
    printf "%s\n" "$line" >>"$LOG_FILE"
    if [ "$level" = "ERROR" ]; then
        printf "%s\n" "$line" >&2
    else
        printf "%s\n" "$line"
    fi
}

if [ ! -f "$ENV_FILE" ]; then
    log ERROR ".env file not found at $ENV_FILE"
    exit 1
fi
source "$ENV_FILE"

FORGEJO_BASE_URL="${FORGEJO_BASE_URL:-https://codeberg.org}"
GITHUB_PAGE_SIZE="${GITHUB_PAGE_SIZE:-100}"
CURL_MAX_RETRIES="${CURL_MAX_RETRIES:-5}"
CURL_RETRY_AFTER_DEFAULT="${CURL_RETRY_AFTER_DEFAULT:-60}"
CODEBERG_REQUEST_DELAY="${CODEBERG_REQUEST_DELAY:-2}"

MIGRATE_CLOSED="${MIGRATE_CLOSED:-true}"
MIGRATE_COMMENTS="${MIGRATE_COMMENTS:-true}"
PRESERVE_LABELS="${PRESERVE_LABELS:-true}"

_errors=0
for _var in GITHUB_USERNAME GITHUB_TOKEN CODEBERG_USERNAME CODEBERG_TOKEN; do
    _val="${!_var}"
    if [ -z "$_val" ]; then
        log ERROR "$_var is not set in .env"
        ((_errors++))
    elif [[ "$_val" == Your* ]]; then
        log ERROR "$_var still has a placeholder value in .env"
        ((_errors++))
    fi
done
[ $_errors -gt 0 ] && exit 1

for _cmd in curl jq; do
    if ! command -v "$_cmd" &>/dev/null; then
        log ERROR "'$_cmd' is required but not installed."
        exit 1
    fi
done

curl_retrying() {
    local max_retries="$CURL_MAX_RETRIES"
    local attempt=0
    local tmpfile response http_status retry_after

    while [ $attempt -le $max_retries ]; do
        tmpfile=$(mktemp)
        response=$(curl -s -w "\n%{http_code}" -D "$tmpfile" "$@")
        http_status=$(printf '%s' "$response" | tail -n 1)

        if [ "$http_status" = "429" ]; then
            retry_after=$(grep -i "^retry-after:" "$tmpfile" | tr -d '\r' | awk '{print $2}')
            retry_after=${retry_after:-$CURL_RETRY_AFTER_DEFAULT}
            rm -f "$tmpfile"
            log WARN "Rate limited (HTTP 429) — waiting ${retry_after}s..."
            sleep "$retry_after"
            ((attempt++))
        else
            rm -f "$tmpfile"
            printf '%s' "$response"
            return 0
        fi
    done
    rm -f "$tmpfile"
    printf '%s' "$response"
    return 1
}

array_contains() {
    local array="$1[@]"
    local seeking=$2
    for element in "${!array}"; do
        [[ $element == "$seeking" ]] && return 0
    done
    return 1
}

printf "\n    ----------------------------------------------"
printf "\n    GitHub Issues → Codeberg Migration"
printf "\n    ----------------------------------------------\n"
printf "\n    GitHub User     : $GITHUB_USERNAME"
printf "\n    Codeberg User   : $CODEBERG_USERNAME"
printf "\n    Migrate closed  : $MIGRATE_CLOSED"
printf "\n    Migrate comments: $MIGRATE_COMMENTS"
printf "\n    Preserve labels : $PRESERVE_LABELS"
if [ ${#REPOSITORIES[@]} -eq 0 ]; then
    printf "\n    Repositories    : all"
else
    printf "\n    Repositories    : %s" "${REPOSITORIES[@]}"
fi
printf "\n\n    Press ENTER to continue, C-c to abort.\n\n"
read

log INFO "Issues migration started"

migrated=0
skipped=0
failed=0

# Get list of repos to process
repos_to_process=()
if [ ${#REPOSITORIES[@]} -eq 0 ]; then
    _user_response=$(curl_retrying -H "Authorization: token $GITHUB_TOKEN" "https://api.github.com/user")
    _user_body=$(printf '%s' "$_user_response" | head -n -1)
    total_repos=$(printf '%s' "$_user_body" | jq '.public_repos + .total_private_repos')
    total_pages=$(((total_repos + GITHUB_PAGE_SIZE - 1) / GITHUB_PAGE_SIZE))

    for ((page = 1; page <= total_pages; page++)); do
        _repos=$(curl_retrying -H "Authorization: token $GITHUB_TOKEN" "https://api.github.com/user/repos?type=owner&per_page=${GITHUB_PAGE_SIZE}&page=${page}")
        repos=$(printf '%s' "$_repos" | head -n -1)
        while read -r repo; do
            repos_to_process+=("$repo")
        done < <(echo "$repos" | jq -r '.[] | "\(.owner.login)/\(.name)"')
    done
else
    for repo in "${REPOSITORIES[@]}"; do
        repos_to_process+=("$GITHUB_USERNAME/$repo")
    done
fi

for repo_full in "${repos_to_process[@]}"; do
    repo_owner=$(echo "$repo_full" | cut -d'/' -f1)
    repo_name=$(echo "$repo_full" | cut -d'/' -f2)

    log INFO "Processing issues for $repo_name..."

    # Get GitHub issues (excluding pull requests)
    state_filter="all"
    _issues_response=$(curl_retrying -H "Authorization: token $GITHUB_TOKEN" \
        "https://api.github.com/repos/$repo_owner/$repo_name/issues?state=$state_filter&per_page=${GITHUB_PAGE_SIZE}")

    _issues_status=$(printf '%s' "$_issues_response" | tail -n 1)
    if [ "$_issues_status" != "200" ]; then
        log ERROR "$repo_name: failed to fetch issues (HTTP $_issues_status)."
        ((failed++))
        continue
    fi

    issues=$(printf '%s' "$_issues_response" | head -n -1)

    # Process each issue
    while read -r issue; do
        issue_number=$(echo "$issue" | jq -r '.number')
        issue_title=$(echo "$issue" | jq -r '.title')
        issue_body=$(echo "$issue" | jq -r '.body // ""')
        issue_state=$(echo "$issue" | jq -r '.state')
        is_pr=$(echo "$issue" | jq -r '.pull_request.url // empty')

        # Skip pull requests (they appear in issues API)
        if [ -n "$is_pr" ]; then
            continue
        fi

        # Skip closed issues if not migrating them
        if [ "$issue_state" = "closed" ] && [ "$MIGRATE_CLOSED" != "true" ]; then
            log INFO "$repo_name#$issue_number: skipping closed issue."
            ((skipped++))
            continue
        fi

        # Get labels
        labels=$(echo "$issue" | jq -r '[.labels[].name] | join(",")')

        # Prepare body with reference to original
        migrated_body="*Migrated from GitHub: https://github.com/$repo_owner/$repo_name/issues/$issue_number*

---

$issue_body"

        # Create issue on Codeberg
        # https://try.gitea.io/api/swagger#/issue/issueCreateIssue
        issue_payload=$(jq -n \
            --arg title "$issue_title" \
            --arg body "$migrated_body" \
            --argjson closed "$([[ "$issue_state" == "closed" ]] && echo "true" || echo "false")" \
            '{title: $title, body: $body, closed: $closed}')

        _create_response=$(curl_retrying -X POST \
            -H "Authorization: token $CODEBERG_TOKEN" \
            -H "Content-Type: application/json" \
            -d "$issue_payload" \
            "$FORGEJO_BASE_URL/api/v1/repos/$CODEBERG_USERNAME/$repo_name/issues")

        _create_status=$(printf '%s' "$_create_response" | tail -n 1)

        if [ "$_create_status" != "201" ]; then
            log ERROR "$repo_name#$issue_number: failed to create on Codeberg (HTTP $_create_status)."
            ((failed++))
            continue
        fi

        new_issue_body=$(printf '%s' "$_create_response" | head -n -1)
        new_issue_number=$(echo "$new_issue_body" | jq -r '.number')

        # Add labels if any
        if [ -n "$labels" ] && [ "$PRESERVE_LABELS" = "true" ]; then
            # Note: Codeberg/Gitea API expects labels in a specific format
            IFS=',' read -ra label_array <<<"$labels"
            for label in "${label_array[@]}"; do
                # Add label to issue (ignore errors, labels might not exist on Codeberg)
                curl -s -X POST \
                    -H "Authorization: token $CODEBERG_TOKEN" \
                    "$FORGEJO_BASE_URL/api/v1/repos/$CODEBERG_USERNAME/$repo_name/issues/$new_issue_number/labels" \
                    -d "labels=$label" >/dev/null 2>&1
            done
        fi

        # Migrate comments if enabled
        if [ "$MIGRATE_COMMENTS" = "true" ]; then
            _comments_response=$(curl_retrying -H "Authorization: token $GITHUB_TOKEN" \
                "https://api.github.com/repos/$repo_owner/$repo_name/issues/$issue_number/comments")

            _comments_status=$(printf '%s' "$_comments_response" | tail -n 1)
            if [ "$_comments_status" = "200" ]; then
                comments=$(printf '%s' "$_comments_response" | head -n -1)

                echo "$comments" | jq -c '.[]' | while read -r comment; do
                    comment_body=$(echo "$comment" | jq -r '.body')
                    comment_user=$(echo "$comment" | jq -r '.user.login')

                    migrated_comment="*Comment by @$comment_user (from GitHub):*

$comment_body"

                    comment_payload=$(jq -n --arg body "$migrated_comment" '{body: $body}')

                    curl -s -X POST \
                        -H "Authorization: token $CODEBERG_TOKEN" \
                        -H "Content-Type: application/json" \
                        -d "$comment_payload" \
                        "$FORGEJO_BASE_URL/api/v1/repos/$CODEBERG_USERNAME/$repo_name/issues/$new_issue_number/comments" >/dev/null 2>&1

                    sleep 0.5
                done
            fi
        fi

        log INFO "$repo_name#$issue_number → Codeberg#$new_issue_number: migrated ($issue_state)."
        ((migrated++))
        sleep "$CODEBERG_REQUEST_DELAY"

    done < <(echo "$issues" | jq -c '.[]')
done

log INFO "Issues migration completed — migrated: $migrated, skipped: $skipped, failed: $failed."
