#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
LOG_FILE="$SCRIPT_DIR/migrate_$(date '+%Y%m%d_%H%M%S').log"

log() {
    local level="$1" msg="$2"
    local line="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $msg"
    printf "%s\n" "$line" >> "$LOG_FILE"
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
DESCRIPTION_PREFIX="${DESCRIPTION_PREFIX:-}"
FORGEJO_BASE_URL="${FORGEJO_BASE_URL:-https://codeberg.org}"
CODEBERG_REQUEST_DELAY="${CODEBERG_REQUEST_DELAY:-2}"
GITHUB_PAGE_SIZE="${GITHUB_PAGE_SIZE:-100}"
CODEBERG_PAGE_SIZE="${CODEBERG_PAGE_SIZE:-50}"
CURL_MAX_RETRIES="${CURL_MAX_RETRIES:-5}"
CURL_RETRY_AFTER_DEFAULT="${CURL_RETRY_AFTER_DEFAULT:-60}"

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

array_contains() {
    local array="$1[@]"
    local seeking=$2
    for element in "${!array}"; do
        [[ $element == "$seeking" ]] && return 0
    done
    return 1
}

printf "\n    ----------------------------------------------"
printf "\n    Welcome to Github to Codeberg Migration Script"
printf "\n    ----------------------------------------------\n"
printf "\n    User on Github          : $GITHUB_USERNAME"
printf "\n    User on Codeberg        : $CODEBERG_USERNAME"
printf "\n    Using description prefix: $DESCRIPTION_PREFIX"
if [ ${#OWNERS[@]} -eq 0 ]; then
    printf "\n    Migrating repos owned by: all users"
else
    printf "\n    Migrating repos owned by: %s" "${OWNERS[@]}"
fi
if [ ${#REPOSITORIES[@]} -eq 0 ]; then
    printf "\n    Migrating repos         : all"
else
    printf "\n    Migrating repos         : %s" "${REPOSITORIES[@]}"
fi
printf "\n    Log file                : %s" "$LOG_FILE"
printf "\n\n    Press ENTER to continue, C-c to abort.\n\n"
read

log INFO "Migration started — GitHub user: $GITHUB_USERNAME, Codeberg user: $CODEBERG_USERNAME"

migrated=0
skipped=0
failed=0

# https://docs.github.com/en/rest/users/users#get-the-authenticated-user
_user_response=$(curl_retrying -H "Authorization: token $GITHUB_TOKEN" "https://api.github.com/user")
_user_body=$(printf '%s' "$_user_response" | head -n -1)
github_total_repos=$(printf '%s' "$_user_body" | jq '.public_repos + .total_private_repos')
github_total_pages=$(( (github_total_repos + GITHUB_PAGE_SIZE - 1) / GITHUB_PAGE_SIZE ))

log INFO "Found $github_total_repos repos across $github_total_pages page(s) on GitHub."

for ((page = 1; page <= github_total_pages; page++)); do
    # https://docs.github.com/en/rest/repos/repos#list-repositories-for-the-authenticated-user
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

        if [ ${#REPOSITORIES[@]} -ne 0 ] && ! array_contains REPOSITORIES "$repo_name"; then
            continue
        fi

        if [ ${#OWNERS[@]} -ne 0 ] && ! array_contains OWNERS "$repo_owner"; then
            continue
        fi

        repo_clone_url=$(echo "$row" | jq -r '.clone_url')
        repo_description="$DESCRIPTION_PREFIX$(echo "$row" | jq -r '.description')"
        repo_is_private=$(echo "$row" | jq -r '.private')
        visibility=$([ "$repo_is_private" = "true" ] && echo "private" || echo "public")

        json_payload=$(jq -n \
            --arg auth_username "$GITHUB_USERNAME" \
            --arg auth_token "$GITHUB_TOKEN" \
            --arg clone_addr "$repo_clone_url" \
            --argjson private "$repo_is_private" \
            --arg repo_name "$repo_name" \
            --arg repo_owner "$CODEBERG_USERNAME" \
            --arg description "$repo_description" \
            '{
                auth_username: $auth_username,
                auth_token: $auth_token,
                clone_addr: $clone_addr,
                private: $private,
                repo_name: $repo_name,
                repo_owner: $repo_owner,
                service: "github",
                description: $description
            }')

        # https://codeberg.org/api/swagger#/repository/repoMigrate
        response=$(curl_retrying -X POST \
            -H "Content-Type: application/json" \
            -H "Authorization: token $CODEBERG_TOKEN" \
            -d "$json_payload" \
            "$FORGEJO_BASE_URL/api/v1/repos/migrate")

        response_body=$(printf '%s' "$response" | head -n -1)
        http_status=$(printf '%s' "$response" | tail -n 1)

        case $http_status in
        201)
            log INFO "$repo_name ($visibility): migrated successfully."
            ((migrated++))
            ;;
        409)
            log INFO "$repo_name ($visibility): skipped — already exists on Codeberg."
            ((skipped++))
            ;;
        403)
            log ERROR "$repo_name ($visibility): forbidden (HTTP 403)."
            ((failed++))
            ;;
        *)
            error_message=$(printf '%s' "$response_body" | jq -r '.message // empty' 2>/dev/null)
            if printf '%s' "$error_message" | grep -qi "limit of.*repositor\|repositor.*limit\|reached your limit"; then
                log ERROR "$repo_name ($visibility): Forgejo repository cap reached. If using Codeberg, request an increase at https://codeberg.org/Codeberg-e.V./requests"
                log INFO "Migration aborted — migrated: $migrated, skipped: $skipped, failed: $((failed + 1))."
                exit 1
            elif [ -n "$error_message" ]; then
                log ERROR "$repo_name ($visibility): $error_message (HTTP $http_status)."
            else
                log ERROR "$repo_name ($visibility): unknown error (HTTP $http_status)."
            fi
            ((failed++))
            ;;
        esac

        sleep "$CODEBERG_REQUEST_DELAY"
    done < <(echo "$repos" | jq -c '.[]')
done

log INFO "Migration completed — migrated: $migrated, skipped: $skipped, failed: $failed."
