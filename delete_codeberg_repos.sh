#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
LOG_FILE="$SCRIPT_DIR/delete_$(date '+%Y%m%d_%H%M%S').log"

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

CODEBERG_PAGE_SIZE="${CODEBERG_PAGE_SIZE:-50}"

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

printf "\n    ----------------------------------------------"
printf "\n    Welcome to Codeberg Repository Deletion Script"
printf "\n    ----------------------------------------------\n"
printf "\n    User on Codeberg: $CODEBERG_USERNAME"
printf "\n    Log file        : $LOG_FILE"
printf "\n\n    Press ENTER to continue, C-c to abort.\n\n"
read

log INFO "Deletion started — Codeberg user: $CODEBERG_USERNAME"

deleted=0
failed=0

while true; do
    # https://codeberg.org/api/swagger#/repository/repoDelete
    repos=$(curl -s -H "Authorization: token $CODEBERG_TOKEN" \
        "https://codeberg.org/api/v1/user/repos?limit=${CODEBERG_PAGE_SIZE}&page=1" \
        | jq -r '.[].name')

    [ -z "$repos" ] && break

    while read -r repo; do
        http_status=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE \
            -H "Authorization: token $CODEBERG_TOKEN" \
            "https://codeberg.org/api/v1/repos/$CODEBERG_USERNAME/$repo")
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
