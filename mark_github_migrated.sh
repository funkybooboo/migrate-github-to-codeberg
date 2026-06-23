#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
LOG_FILE="$SCRIPT_DIR/mark_migrated_$(date '+%Y%m%d_%H%M%S').log"

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
    log ERROR ".env file not found at $ENV_FILE — copy .env.example to .env and fill in your credentials."
    exit 1
fi
source "$ENV_FILE"

FORGEJO_BASE_URL="${FORGEJO_BASE_URL:-https://codeberg.org}"
GITHUB_PAGE_SIZE="${GITHUB_PAGE_SIZE:-100}"
CURL_MAX_RETRIES="${CURL_MAX_RETRIES:-5}"
CURL_RETRY_AFTER_DEFAULT="${CURL_RETRY_AFTER_DEFAULT:-60}"

MIGRATION_NOTICE="${MIGRATION_NOTICE:-"This repository has been migrated to Codeberg. Active development continues there."}"
MIGRATION_PREFIX="${MIGRATION_PREFIX:-"[ARCHIVED] Migrated to Codeberg: "}"
DISABLE_ISSUES="${DISABLE_ISSUES:-true}"
DISABLE_PROJECTS="${DISABLE_PROJECTS:-true}"
DISABLE_WIKI="${DISABLE_WIKI:-true}"
CREATE_PINNED_ISSUE="${CREATE_PINNED_ISSUE:-true}"

_errors=0
for _var in GITHUB_USERNAME GITHUB_TOKEN CODEBERG_USERNAME; do
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

url_encode() {
    local string="$1"
    local encoded=""
    local pos c o

    for ((pos = 0; pos < ${#string}; pos++)); do
        c=${string:$pos:1}
        case "$c" in
        [a-zA-Z0-9.~_-]) encoded+="$c" ;;
        *)
            printf -v o '%%%02x' "'$c"
            encoded+="$o"
            ;;
        esac
    done
    echo "$encoded"
}

printf "\n    ----------------------------------------------"
printf "\n    Welcome to GitHub Archive & Migration Marker"
printf "\n    ----------------------------------------------\n"
printf "\n    GitHub User     : $GITHUB_USERNAME"
printf "\n    Codeberg User   : $CODEBERG_USERNAME"
printf "\n    Forgejo URL     : $FORGEJO_BASE_URL"
printf "\n    Disable issues  : $DISABLE_ISSUES"
printf "\n    Disable projects: $DISABLE_PROJECTS"
printf "\n    Disable wiki    : $DISABLE_WIKI"
printf "\n    Create pinned   : $CREATE_PINNED_ISSUE"
if [ ${#REPOSITORIES[@]} -eq 0 ]; then
    printf "\n    Repos to mark   : all"
else
    printf "\n    Repos to mark   : %s" "${REPOSITORIES[@]}"
fi
printf "\n    Log file        : %s" "$LOG_FILE"
printf "\n\n    This script will:"
printf "\n      1. Archive repositories on GitHub"
printf "\n      2. Update descriptions to indicate migration"
printf "\n      3. Prepend migration notice to README"
printf "\n      4. Disable issues, projects, and wiki (optional)"
printf "\n      5. Create pinned 'we moved' issue (optional)"
printf "\n\n    Press ENTER to continue, C-c to abort.\n\n"
read

log INFO "Mark as migrated started — GitHub user: $GITHUB_USERNAME, Codeberg user: $CODEBERG_USERNAME"

marked=0
skipped=0
failed=0

_user_response=$(curl_retrying -H "Authorization: token $GITHUB_TOKEN" "https://api.github.com/user")
_user_body=$(printf '%s' "$_user_response" | head -n -1)
github_total_repos=$(printf '%s' "$_user_body" | jq '.public_repos + .total_private_repos')
github_total_pages=$(((github_total_repos + GITHUB_PAGE_SIZE - 1) / GITHUB_PAGE_SIZE))

log INFO "Found $github_total_repos repos across $github_total_pages page(s) on GitHub."

for ((page = 1; page <= github_total_pages; page++)); do
    _repos_response=$(curl_retrying -H "Authorization: token $GITHUB_TOKEN" "https://api.github.com/user/repos?type=owner&per_page=${GITHUB_PAGE_SIZE}&page=${page}")
    repos=$(printf '%s' "$_repos_response" | head -n -1)
    _repos_status=$(printf '%s' "$_repos_response" | tail -n 1)

    if [ "$_repos_status" != "200" ]; then
        error_message=$(printf '%s' "$repos" | jq -r '.message // empty' 2>/dev/null)
        log ERROR "Failed to fetch repos page $page (HTTP $_repos_status)${error_message:+: $error_message}."
        exit 1
    fi

    while read -r row; do
        repo_name=$(echo "$row" | jq -r '.name')
        repo_owner=$(echo "$row" | jq -r '.owner.login')
        current_desc=$(echo "$row" | jq -r '.description // ""')
        is_archived=$(echo "$row" | jq -r '.archived')
        default_branch=$(echo "$row" | jq -r '.default_branch // "main"')

        if [ ${#REPOSITORIES[@]} -ne 0 ] && ! array_contains REPOSITORIES "$repo_name"; then
            continue
        fi

        if [ ${#OWNERS[@]} -ne 0 ] && ! array_contains OWNERS "$repo_owner"; then
            continue
        fi

        if [ "$is_archived" = "true" ]; then
            log INFO "$repo_name: already archived, skipping."
            ((skipped++))
            continue
        fi

        codeberg_url="$FORGEJO_BASE_URL/$CODEBERG_USERNAME/$repo_name"

        # Step 1: Archive repo, update description, disable features
        new_desc="${MIGRATION_PREFIX}${codeberg_url}${current_desc:+ — $current_desc}"

        update_payload=$(jq -n \
            --arg desc "$new_desc" \
            --argjson has_issues "$([[ "$DISABLE_ISSUES" == "true" ]] && echo "false" || echo "true")" \
            --argjson has_projects "$([[ "$DISABLE_PROJECTS" == "true" ]] && echo "false" || echo "true")" \
            --argjson has_wiki "$([[ "$DISABLE_WIKI" == "true" ]] && echo "false" || echo "true")" \
            '{archived: true, description: $desc, has_issues: $has_issues, has_projects: $has_projects, has_wiki: $has_wiki}')

        _update_response=$(curl_retrying -X PATCH \
            -H "Authorization: token $GITHUB_TOKEN" \
            -H "Accept: application/vnd.github.v3+json" \
            -H "Content-Type: application/json" \
            -d "$update_payload" \
            "https://api.github.com/repos/$repo_owner/$repo_name")

        _update_status=$(printf '%s' "$_update_response" | tail -n 1)

        if [ "$_update_status" != "200" ]; then
            log ERROR "$repo_name: failed to archive/update repo (HTTP $_update_status)."
            ((failed++))
            continue
        fi

        log INFO "$repo_name: archived, description updated, features disabled."

        # Step 2: Update README with migration notice
        _readme_response=$(curl_retrying -H "Authorization: token $GITHUB_TOKEN" \
            "https://api.github.com/repos/$repo_owner/$repo_name/readme")

        _readme_status=$(printf '%s' "$_readme_response" | tail -n 1)

        if [ "$_readme_status" = "404" ]; then
            log INFO "$repo_name: no README found, skipping README update."
        elif [ "$_readme_status" = "200" ]; then
            readme_body=$(printf '%s' "$_readme_response" | head -n -1)
            current_content=$(echo "$readme_body" | jq -r '.content' | tr -d '\n' | base64 -d 2>/dev/null)
            readme_sha=$(echo "$readme_body" | jq -r '.sha')
            readme_path=$(echo "$readme_body" | jq -r '.path')

            if [ -n "$current_content" ]; then
                migration_banner="> [!IMPORTANT]
> $MIGRATION_NOTICE
>
> **New location:** [$codeberg_url]($codeberg_url)

"
                new_content="${migration_banner}${current_content}"
                new_content_b64=$(echo "$new_content" | base64 -w 0)

                commit_message="docs: add migration notice to README [automated]"

                readme_payload=$(jq -n \
                    --arg message "$commit_message" \
                    --arg content "$new_content_b64" \
                    --arg sha "$readme_sha" \
                    '{message: $message, content: $content, sha: $sha}')

                _readme_update=$(curl_retrying -X PUT \
                    -H "Authorization: token $GITHUB_TOKEN" \
                    -H "Accept: application/vnd.github.v3+json" \
                    -H "Content-Type: application/json" \
                    -d "$readme_payload" \
                    "https://api.github.com/repos/$repo_owner/$repo_name/contents/$(url_encode "$readme_path")")

                _readme_update_status=$(printf '%s' "$_readme_update" | tail -n 1)

                if [ "$_readme_update_status" = "200" ] || [ "$_readme_update_status" = "201" ]; then
                    log INFO "$repo_name: README updated with migration notice."
                else
                    log WARN "$repo_name: README update failed (HTTP $_readme_update_status)."
                fi
            else
                log WARN "$repo_name: could not decode README content."
            fi
        else
            log WARN "$repo_name: README fetch failed (HTTP $_readme_status)."
        fi

        # Step 3: Create pinned "we moved" issue
        if [ "$CREATE_PINNED_ISSUE" = "true" ]; then
            issue_payload=$(jq -n \
                --arg title "⚠️ Repository Moved to Codeberg" \
                --arg body "This repository has been migrated to **Codeberg**: [$codeberg_url]($codeberg_url)

All future development, issues, and pull requests will take place there.

This GitHub repository is now archived and read-only." \
                '{title: $title, body: $body}')

            _issue_response=$(curl_retrying -X POST \
                -H "Authorization: token $GITHUB_TOKEN" \
                -H "Accept: application/vnd.github.v3+json" \
                -H "Content-Type: application/json" \
                -d "$issue_payload" \
                "https://api.github.com/repos/$repo_owner/$repo_name/issues")

            _issue_status=$(printf '%s' "$_issue_response" | tail -n 1)

            if [ "$_issue_status" = "201" ]; then
                issue_body=$(printf '%s' "$_issue_response" | head -n -1)
                issue_number=$(echo "$issue_body" | jq -r '.number')

                # Pin the issue
                _pin_response=$(curl_retrying -X PUT \
                    -H "Authorization: token $GITHUB_TOKEN" \
                    -H "Accept: application/vnd.github.v3+json" \
                    "https://api.github.com/repos/$repo_owner/$repo_name/pins/issues/$issue_number")

                _pin_status=$(printf '%s' "$_pin_response" | tail -n -1)

                if [ "$_pin_status" = "204" ]; then
                    log INFO "$repo_name: created and pinned migration issue #$issue_number."
                else
                    log INFO "$repo_name: created migration issue #$issue_number (pin failed HTTP $_pin_status)."
                fi
            else
                log WARN "$repo_name: failed to create migration issue (HTTP $_issue_status)."
            fi
        fi

        ((marked++))
        sleep 1
    done < <(echo "$repos" | jq -c '.[]')
done

log INFO "Mark as migrated completed — marked: $marked, skipped: $skipped, failed: $failed."
