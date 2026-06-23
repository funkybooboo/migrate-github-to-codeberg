#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
LOG_FILE="$SCRIPT_DIR/pr_references_$(date '+%Y%m%d_%H%M%S').log"

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

printf "\n    ----------------------------------------------"
printf "\n    GitHub PRs → Codeberg References"
printf "\n    ----------------------------------------------\n"
printf "\n    Note: PRs cannot be truly migrated (they are git refs)."
printf "\n    This script creates issues on Codeberg referencing"
printf "\n    the original GitHub PRs for historical tracking."
printf "\n\n    Press ENTER to continue, C-c to abort.\n\n"
read

log INFO "PR references creation started"

created=0
failed=0

for repo in "${REPOSITORIES[@]}"; do
    log INFO "Processing PRs for $repo..."

    # Get closed/merged PRs from GitHub
    _prs_response=$(curl_retrying -H "Authorization: token $GITHUB_TOKEN" \
        "https://api.github.com/repos/$GITHUB_USERNAME/$repo/pulls?state=all&per_page=${GITHUB_PAGE_SIZE}")

    _prs_status=$(printf '%s' "$_prs_response" | tail -n 1)
    if [ "$_prs_status" != "200" ]; then
        log ERROR "$repo: failed to fetch PRs (HTTP $_prs_status)."
        ((failed++))
        continue
    fi

    prs=$(printf '%s' "$_prs_response" | head -n -1)

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
            "$FORGEJO_BASE_URL/api/v1/repos/$CODEBERG_USERNAME/$repo/issues")

        _create_status=$(printf '%s' "$_create_response" | tail -n -1)

        if [ "$_create_status" = "201" ]; then
            log INFO "$repo PR #$pr_number: reference created on Codeberg."
            ((created++))
        else
            log ERROR "$repo PR #$pr_number: failed to create reference (HTTP $_create_status)."
            ((failed++))
        fi

        sleep "$CODEBERG_REQUEST_DELAY"

    done < <(echo "$prs" | jq -c '.[]')
done

log INFO "PR references completed — created: $created, failed: $failed."
