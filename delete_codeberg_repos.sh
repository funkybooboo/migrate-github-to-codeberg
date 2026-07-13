#!/usr/bin/env bash
# delete_codeberg_repos.sh -- delete every repository owned by
# CODEBERG_USERNAME. Useful for wiping a test migration before re-running.

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

FORGEJO_BASE_URL="${FORGEJO_BASE_URL:-https://codeberg.org}"
CODEBERG_PAGE_SIZE="${CODEBERG_PAGE_SIZE:-50}"
CURL_MAX_RETRIES="${CURL_MAX_RETRIES:-5}"
CURL_RETRY_AFTER_DEFAULT="${CURL_RETRY_AFTER_DEFAULT:-60}"

_errors=0
for _var in CODEBERG_USERNAME CODEBERG_TOKEN; do
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

# Wraps curl, automatically retrying on HTTP 429 by honouring the retry-after
# header (defaulting to 60 s if absent). All other curl flags are passed through.
# Output format: response_body\nhttp_status  (same as curl -s -w "\n%{http_code}")
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

printf "\n    ----------------------------------------------"
printf "\n    Welcome to Codeberg Repository Deletion Script"
printf "\n    ----------------------------------------------\n"
printf "\n    User on Codeberg: $CODEBERG_USERNAME"
printf "\n    Forgejo URL     : $FORGEJO_BASE_URL"
printf "\n\n    *** THIS IS IRREVERSIBLE — every repo owned by"
printf "\n        $CODEBERG_USERNAME will be deleted. ***"
printf "\n\n    Press ENTER to continue, C-c to abort.\n\n"
read

log INFO "Deletion started — Codeberg user: $CODEBERG_USERNAME"

deleted=0
failed=0

while true; do
    # https://codeberg.org/api/swagger#/repository/repoList
    _list_response=$(curl_retrying -H "Authorization: token $CODEBERG_TOKEN" \
        "$FORGEJO_BASE_URL/api/v1/user/repos?limit=${CODEBERG_PAGE_SIZE}&page=1")

    _list_status=$(printf '%s' "$_list_response" | tail -n 1)
    if [ "$_list_status" != "200" ]; then
        log ERROR "Failed to list repos (HTTP $_list_status)."
        exit 1
    fi

    repos=$(printf '%s' "$_list_response" | head -n -1 | jq -r '.[].name')
    [ -z "$repos" ] && break

    while read -r repo; do
        _del_response=$(curl_retrying -X DELETE \
            -H "Authorization: token $CODEBERG_TOKEN" \
            "$FORGEJO_BASE_URL/api/v1/repos/$CODEBERG_USERNAME/$repo")
        http_status=$(printf '%s' "$_del_response" | tail -n 1)
        case $http_status in
        204)
            log INFO "$repo: deleted."
            ((deleted++))
            ;;
        404)
            log INFO "$repo: already gone."
            ;;
        *)
            log ERROR "$repo: failed to delete (HTTP $http_status)."
            ((failed++))
            ;;
        esac
    done <<< "$repos"
done

log INFO "Deletion completed — deleted: $deleted, failed: $failed."