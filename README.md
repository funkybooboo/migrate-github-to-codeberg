# GitHub to Codeberg Migration Scripts

Two scripts for managing a GitHub-to-Codeberg migration:

- `migrate_github_to_codeberg.sh` — mirrors repositories from GitHub to Codeberg
- `delete_codeberg_repos.sh` — deletes all repositories from a Codeberg account

## Requirements

- `bash`
- `curl` ([docs](https://curl.se/docs/))
- `jq` ([docs](https://jqlang.org/))

On Debian/Ubuntu: `sudo apt install curl jq`
On macOS: `brew install curl jq`

## Setup

Copy `.env.example` to `.env` and fill in your credentials:

```sh
cp .env.example .env
```

### .env reference

| Variable             | Required | Description                                              |
|----------------------|----------|----------------------------------------------------------|
| `GITHUB_USERNAME`    | yes      | Your GitHub username                                     |
| `GITHUB_TOKEN`       | yes      | GitHub personal access token (needs `repo` scope)        |
| `CODEBERG_USERNAME`  | yes      | Your Codeberg username                                   |
| `CODEBERG_TOKEN`     | yes      | Codeberg personal access token                           |
| `REPOSITORIES`       | no       | Bash array of repo names to migrate. Empty = all.        |
| `OWNERS`             | no       | Bash array of owner logins to filter by. Empty = all.    |
| `DESCRIPTION_PREFIX`       | no       | String prepended to each repo description. Default: `""`       |
| `CODEBERG_REQUEST_DELAY`   | no       | Seconds to sleep between Codeberg migration calls. Default: `2`          |
| `GITHUB_PAGE_SIZE`         | no       | Repos fetched per GitHub API page. Max/default: `100`                    |
| `CODEBERG_PAGE_SIZE`       | no       | Repos fetched per Codeberg API page. Max/default: `50`                   |
| `CURL_MAX_RETRIES`         | no       | Max retries on HTTP 429 before giving up. Default: `5`                   |
| `CURL_RETRY_AFTER_DEFAULT` | no       | Fallback wait (seconds) on 429 with no `retry-after` header. Default: `60` |

### Generating tokens

- GitHub: [Managing personal access tokens](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens) — requires `repo` scope
- Codeberg: [Generating an access token](https://docs.codeberg.org/advanced/access-token/)

## Usage

### Migrate repositories

```sh
./migrate_github_to_codeberg.sh
```

Fetches all repositories from GitHub ([GET /user/repos](https://docs.github.com/en/rest/repos/repos#list-repositories-for-the-authenticated-user), paginated at 100) and mirrors
them to Codeberg via the [migration API](https://codeberg.org/api/swagger#/repository/repoMigrate). Preserves name, description, and private/public status.

**Safety notices:**
- Your GitHub token is sent to the Codeberg API as part of the migration payload so Codeberg can pull the source repo. Use a token with the minimum required scope (`repo`) and revoke it when done.
- Private repositories will be created as private on Codeberg, but verify after migration.
- The script does not check whether a repo was already partially migrated — re-running will report a 409 conflict for any repo that already exists.

To migrate only specific repos, set `REPOSITORIES` in `.env`:

```sh
REPOSITORIES=(
    "my-project"
    "dotfiles"
)
```

To migrate only repos owned by specific users, set `OWNERS`:

```sh
OWNERS=(
    "myusername"
    "some-org"
)
```

### Delete all Codeberg repositories

```sh
./delete_codeberg_repos.sh
```

Deletes every repository owned by `CODEBERG_USERNAME` via the [Codeberg delete API](https://codeberg.org/api/swagger#/repository/repoDelete).
Useful for wiping a test migration before re-running.

**Safety notices:**
- **This is irreversible.** Deleted repositories cannot be recovered.
- There is no per-repo confirmation — all repos are deleted without further prompts after the initial ENTER.
- Org-owned repositories are not affected; only repos owned directly by `CODEBERG_USERNAME` are deleted.

## Limitations

The [migration API](https://codeberg.org/api/swagger#/repository/repoMigrate) does not transfer:

- Forks (mirrored as standalone repos)
- Issues and pull requests
- Wikis
- Project avatars

## Rate limits & quotas

### GitHub (source)

| Limit | Value |
|---|---|
| Authenticated REST API rate limit | 5,000 requests / hour |
| Secondary: concurrent requests | 100 (shared across REST + GraphQL) |
| Secondary: content-creating requests | 80 / min, 500 / hour |
| `per_page` maximum | 100 items |

The script fetches repos in pages of 100 and makes one API call per page plus one call to `GET /user` for the total count. For most users this is well within the 5,000 req/hour primary limit.

Rate limit status is returned in every response via `x-ratelimit-remaining` and `x-ratelimit-reset` headers. If you hit the limit GitHub returns `403` or `429` with a `retry-after` header.

> [GitHub rate limit docs](https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api)

### Codeberg (destination)

| Limit | Value |
|---|---|
| API rate limit (HAProxy layer) | ~2,000 requests / 300 seconds |
| `per_page` maximum | 50 items |
| **Repositories per user/org (default)** | **100** |
| Git storage per user/org | 750 MiB |
| LFS + packages + releases + attachments | 1.5 GiB additional |

**The 100-repo default cap is the most likely limit you will hit.** If you have more than 100 GitHub repositories, the migration will fail with an error once the cap is reached. You can request an increase at [codeberg.org/Codeberg-e.V./requests](https://codeberg.org/Codeberg-e.V./requests) — increases to 500 or more are routinely granted.

The `/repos/migrate` endpoint is subject to the same 2,000 req/300 s HAProxy limit as all other Codeberg API calls. Migrations are processed asynchronously, so the API call returns immediately, but the underlying clone runs in the background. If a large migration gets stuck in an "in-progress" state, delete the repo from Codeberg settings to free the namespace and retry.

For large batches, adding a short delay between migration calls (e.g. `sleep 2`) is a community-recommended courtesy.

> [Codeberg rate limit issue](https://codeberg.org/Codeberg/Community/issues/425) · [Codeberg storage limits](https://blog.codeberg.org/new-storage-limits-on-codeberg-what-you-need-to-know.html) · [Request a quota increase](https://codeberg.org/Codeberg-e.V./requests)

## API reference

- [GitHub — GET /user](https://docs.github.com/en/rest/users/users#get-the-authenticated-user)
- [GitHub — GET /user/repos](https://docs.github.com/en/rest/repos/repos#list-repositories-for-the-authenticated-user)
- [Codeberg API (Swagger)](https://codeberg.org/api/swagger)
- [Codeberg — POST /repos/migrate](https://codeberg.org/api/swagger#/repository/repoMigrate)
- [Codeberg — DELETE /repos/{owner}/{repo}](https://codeberg.org/api/swagger#/repository/repoDelete)

## Example output

```
    ----------------------------------------------
    Welcome to Github to Codeberg Migration Script
    ----------------------------------------------

    User on Github          : funkybooboo
    User on Codeberg        : funkybooboo
    Using description prefix: [MIRROR]
    Migrating repos owned by: all users
    Migrating repos         : all

    Press ENTER to continue, C-c to abort.

>>> Working...
>>> Migrating: dotfiles (public)... Success!
>>> Migrating: my-project (private)... Already exists on Codeberg.
>>> Migration script completed!
```
