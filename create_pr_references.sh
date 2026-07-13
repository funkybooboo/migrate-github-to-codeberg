#!/usr/bin/env bash
# create_pr_references.sh -- GitHub PRs cannot be truly migrated (they are git
# refs), so this script creates closed issues on Codeberg that reference the
# original GitHub PRs, preserving author/status/body for historical tracking.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

log() {
    local level="$1" msg="$2"
    local line="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $msg"
    if [ "$level" = "ERROR" ]; then
        printf "%s\n" "$line" >&2
    else
        printf "%s\n" "$line"
    fi
}

if [ ! -f "$ENV_FILE" ]; then
    log ERROR ".env file not found at $ENV_FILE — copy .env.example to .env and fill in your credentials."
    exit 1
fi
source "$ENV_FILE"

REPOSITORIES=("${REPOSITORIES[@]}")
OWNERS=("${OWNERS[@]}")
FORGEJO_BASE_URL="${FORGEJO_BASE_URL:-https://codeberg.org}"
GITHUB_PAGE_SIZE="${GITHUB_PAGE_SIZE:-100}"
CURL_MAX_RETRIES="${CURL_MAX_RETRIES:-5}"
CURL_RETRY_AFTER_DEFAULT="${CURL_RETRY_AFTER_DEFAULT:-60}"
CODEBERG_REQUEST_DELAY="${CODEBERG_REQUEST_DELAY:-2}"

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
            log WARN "Rate limited (HTTP 429) — waiting ${retry_after}s before retry (attempt $((attempt + 1))/$max_retries)..."
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
printf "\n    GitHub PRs → Codeberg References"
printf "\n    ----------------------------------------------\n"
printf "\n    Note: PRs cannot be truly migrated (they are git refs)."
printf "\n    This script creates issues on Codeberg referencing"
printf "\n    the original GitHub PRs for historical tracking."
if [ ${#REPOSITORIES[@]} -eq 0 ]; then
    printf "\n    Repositories    : all"
else
    printf "\n    Repositories    : %s" "${REPOSITORIES[@]}"
fi
if [ ${#OWNERS[@]} -eq 0 ]; then
    printf "\n    Owners          : all"
else
    printf "\n    Owners          : %s" "${OWNERS[@]}"
fi
printf "\n    Codeberg User   : $CODEBERG_USERNAME"
printf "\n\n    Press ENTER to continue, C-c to abort.\n\n"
read

log INFO "PR references creation started"

created=0
failed=0

# Build the list of owner/repo pairs to process.
repos_to_process=()
if [ ${#REPOSITORIES[@]} -eq 0 ]; then
    # Fetch every repo owned by the authenticated user (with optional OWNER filter).
    _user_response=$(curl_retrying -H "Authorization: token $GITHUB_TOKEN" "https://api.github.com/user")
    _user_body=$(printf '%s' "$_user_response" | head -n -1)
    total_repos=$(printf '%s' "$_user_body" | jq '.public_repos + .total_private_repos')
    total_pages=$(( (total_repos + GITHUB_PAGE_SIZE - 1) / GITHUB_PAGE_SIZE ))
    log INFO "Found $total_repos repos across $total_pages page(s) on GitHub."

    for ((page = 1; page <= total_pages; page++)); do
        _repos_response=$(curl_retrying -H "Authorization: token $GITHUB_TOKEN" \
            "https://api.github.com/user/repos?type=owner&per_page=${GITHUB_PAGE_SIZE}&page=${page}")
        _repos_status=$(printf '%s' "$_repos_response" | tail -n 1)
        if [ "$_repos_status" != "200" ]; then
            _msg=$(printf '%s' "$_repos_response" | head -n -1 | jq -r '.message // empty' 2>/dev/null)
            log ERROR "Failed to fetch repos page $page (HTTP $_repos_status)${_msg:+: $_msg}."
            exit 1
        fi
        repos=$(printf '%s' "$_repos_response" | head -n -1)
        while read -r row; do
            _r_owner=$(printf '%s' "$row" | jq -r '.owner.login')
            _r_name=$(printf '%s' "$row" | jq -r '.name')
            if [ ${#OWNERS[@]} -ne 0 ] && ! array_contains OWNERS "$_r_owner"; then
                continue
            fi
            repos_to_process+=("$_r_owner/$_r_name")
        done < <(printf '%s' "$repos" | jq -c '.[]')
    done
else
    for repo in "${REPOSITORIES[@]}"; do
        repos_to_process+=("$GITHUB_USERNAME/$repo")
    done
fi

log INFO "Processing PRs for ${#repos_to_process[@]} repo(s)."

for repo_full in "${repos_to_process[@]}"; do
    repo_owner=$(printf '%s' "$repo_full" | cut -d'/' -f1)
    repo_name=$(printf '%s' "$repo_full" | cut -d'/' -f2)
    log INFO "Processing PRs for $repo_name..."

    # Get all PRs from GitHub, paginating until an empty page is returned.
    pr_page=1
    while true; do
        # https://docs.github.com/en/rest/pulls/pulls#list-pull-requests
        _prs_response=$(curl_retrying -H "Authorization: token $GITHUB_TOKEN" \
            "https://api.github.com/repos/$repo_owner/$repo_name/pulls?state=all&per_page=${GITHUB_PAGE_SIZE}&page=${pr_page}")

        _prs_status=$(printf '%s' "$_prs_response" | tail -n 1)
        if [ "$_prs_status" != "200" ]; then
            log ERROR "$repo_name: failed to fetch PRs page $pr_page (HTTP $_prs_status)."
            ((failed++))
            break
        fi

        prs=$(printf '%s' "$_prs_response" | head -n -1)
        # Empty array → no more pages.
        if [ "$(printf '%s' "$prs" | jq 'length')" -eq 0 ]; then
            break
        fi

        while read -r pr; do
            pr_number=$(echo "$pr" | jq -r '.number')
            pr_title=$(echo "$pr" | jq -r '.title')
            pr_body=$(echo "$pr" | jq -r '.body // ""')
            pr_state=$(echo "$pr" | jq -r '.state')
            pr_merged=$(echo "$pr" | jq -r '.merged')
            pr_user=$(echo "$pr" | jq -r '.user.login')
            pr_url=$(echo "$pr" | jq -r '.html_url')

            status_text="OPEN"
            [ "$pr_state" = "closed" ] && status_text="CLOSED"
            [ "$pr_merged" = "true" ] && status_text="MERGED"

            # Create reference issue on Codeberg
            ref_body="## Historical Pull Request Reference

**Original PR:** [$pr_title]($pr_url)

- **Author:** @$pr_user
- **Status:** $status_text
- **GitHub PR #:** $pr_number

---

$pr_body"

            issue_payload=$(jq -n \
                --arg title "[PR Reference] $pr_title" \
                --arg body "$ref_body" \
                --argjson closed true \
                '{title: $title, body: $body, closed: $closed}')

            _create_response=$(curl_retrying -X POST \
                -H "Authorization: token $CODEBERG_TOKEN" \
                -H "Content-Type: application/json" \
                -d "$issue_payload" \
                "$FORGEJO_BASE_URL/api/v1/repos/$CODEBERG_USERNAME/$repo_name/issues")

            _create_status=$(printf '%s' "$_create_response" | tail -n 1)

            if [ "$_create_status" = "201" ]; then
                log INFO "$repo_name PR #$pr_number: reference created on Codeberg."
                ((created++))
            else
                log ERROR "$repo_name PR #$pr_number: failed to create reference (HTTP $_create_status)."
                ((failed++))
            fi

            sleep "$CODEBERG_REQUEST_DELAY"

        done < <(printf '%s' "$prs" | jq -c '.[]')

        ((pr_page++))
    done
done

log INFO "PR references completed — created: $created, failed: $failed."