#!/usr/bin/env bash
# update_github_profile.sh -- update the GitHub profile bio and (optionally)
# prepend a migration notice to the profile README repo (<user>/<user>).

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
GITHUB_PAGE_SIZE="${GITHUB_PAGE_SIZE:-100}"
CURL_MAX_RETRIES="${CURL_MAX_RETRIES:-5}"
CURL_RETRY_AFTER_DEFAULT="${CURL_RETRY_AFTER_DEFAULT:-60}"

PROFILE_BIO="${PROFILE_BIO:-}"
UPDATE_README="${UPDATE_README:-true}"
MIGRATION_NOTICE="${MIGRATION_NOTICE:-"This repository has been migrated to Codeberg. Active development continues there."}"

_errors=0
for _var in GITHUB_USERNAME GITHUB_TOKEN; do
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

url_encode() {
    local string="$1"
    local encoded="" pos c o
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
printf "\n    Welcome to GitHub Profile Update Script"
printf "\n    ----------------------------------------------\n"
printf "\n    GitHub User     : $GITHUB_USERNAME"
printf "\n    Forgejo URL     : $FORGEJO_BASE_URL"
printf "\n    Update bio      : %s" "$([ -n "$PROFILE_BIO" ] && echo "yes" || echo "no (PROFILE_BIO empty)")"
printf "\n    Update README   : $UPDATE_README"
printf "\n\n    This script will:"
printf "\n      1. Update your GitHub profile bio (PATCH /user)"
printf "\n      2. Prepend a migration notice to your profile README repo (%s/%s)" "$GITHUB_USERNAME" "$GITHUB_USERNAME"
printf "\n\n    Press ENTER to continue, C-c to abort.\n\n"
read

log INFO "Profile update started — GitHub user: $GITHUB_USERNAME"

updated=0
failed=0

# Step 1: update profile bio
if [ -n "$PROFILE_BIO" ]; then
    bio_payload=$(jq -n --arg bio "$PROFILE_BIO" '{bio: $bio}')

    _bio_response=$(curl_retrying -X PATCH \
        -H "Authorization: token $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github.v3+json" \
        -H "Content-Type: application/json" \
        -d "$bio_payload" \
        "https://api.github.com/user")

    _bio_status=$(printf '%s' "$_bio_response" | tail -n 1)

    if [ "$_bio_status" = "200" ]; then
        log INFO "Profile bio updated."
        ((updated++))
    else
        _bio_body=$(printf '%s' "$_bio_response" | head -n -1)
        _bio_msg=$(printf '%s' "$_bio_body" | jq -r '.message // empty' 2>/dev/null)
        log ERROR "Failed to update profile bio (HTTP $_bio_status)${_bio_msg:+: $_bio_msg}."
        ((failed++))
    fi
else
    log INFO "PROFILE_BIO is empty — skipping bio update."
fi

# Step 2: prepend migration notice to the profile README repo (<user>/<user>)
if [ "$UPDATE_README" = "true" ]; then
    profile_repo="$GITHUB_USERNAME/$GITHUB_USERNAME"

    # https://docs.github.com/en/rest/repos/repos#get-a-repository-readme
    _readme_response=$(curl_retrying \
        -H "Authorization: token $GITHUB_TOKEN" \
        "https://api.github.com/repos/$profile_repo/readme")

    _readme_status=$(printf '%s' "$_readme_response" | tail -n 1)

    case "$_readme_status" in
    404)
        log WARN "Profile README repo $profile_repo not found or has no README — skipping README update."
        ;;
    200)
        readme_body=$(printf '%s' "$_readme_response" | head -n -1)
        current_content=$(printf '%s' "$readme_body" | jq -r '.content' | tr -d '\n' | base64 -d 2>/dev/null)
        readme_sha=$(printf '%s' "$readme_body" | jq -r '.sha')
        readme_path=$(printf '%s' "$readme_body" | jq -r '.path')

        if [ -z "$current_content" ]; then
            log WARN "Could not decode README content for $profile_repo — skipping."
        else
            codeberg_url="$FORGEJO_BASE_URL/$GITHUB_USERNAME"
            migration_banner="> [!IMPORTANT]
> $MIGRATION_NOTICE
>
> **New location:** [$codeberg_url]($codeberg_url)

"
            new_content="${migration_banner}${current_content}"
            new_content_b64=$(printf '%s' "$new_content" | base64 -w 0)

            readme_payload=$(jq -n \
                --arg message "docs: add migration notice to profile README [automated]" \
                --arg content "$new_content_b64" \
                --arg sha "$readme_sha" \
                '{message: $message, content: $content, sha: $sha}')

            _readme_update=$(curl_retrying -X PUT \
                -H "Authorization: token $GITHUB_TOKEN" \
                -H "Accept: application/vnd.github.v3+json" \
                -H "Content-Type: application/json" \
                -d "$readme_payload" \
                "https://api.github.com/repos/$profile_repo/contents/$(url_encode "$readme_path")")

            _readme_update_status=$(printf '%s' "$_readme_update" | tail -n 1)

            if [ "$_readme_update_status" = "200" ] || [ "$_readme_update_status" = "201" ]; then
                log INFO "Profile README ($profile_repo) updated with migration notice."
                ((updated++))
            else
                log ERROR "Failed to update profile README (HTTP $_readme_update_status)."
                ((failed++))
            fi
        fi
        ;;
    *)
        log ERROR "Failed to fetch profile README from $profile_repo (HTTP $_readme_status)."
        ((failed++))
        ;;
    esac
fi

log INFO "Profile update completed — updated: $updated, failed: $failed."
