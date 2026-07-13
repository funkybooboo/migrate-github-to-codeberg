# GitHub to Codeberg Migration Toolkit

A set of bash scripts for migrating a GitHub account (or selected repos) to
Codeberg or any other Gitea/Forgejo instance. All scripts share a single
`.env` configuration file.

## Scripts

| Script | What it does | Destroys GitHub data? |
|---|---|---|
| `migrate_github_to_codeberg.sh` | Mirror repositories (source + description + visibility) to Codeberg via the migration API | No |
| `migrate_issues_to_codeberg.sh` | Copy issues (and optionally comments + labels) to Codeberg | No (read-only on GitHub) |
| `create_pr_references.sh` | Create closed Codeberg issues that reference the original GitHub PRs (PRs can't be truly migrated) | No |
| `mark_github_migrated.sh` | Archive GitHub repos, update descriptions, insert a migration banner in each README, disable issues/projects/wiki, optionally pin a "we moved" issue | Yes — archives + disables features on GitHub |
| `update_github_profile.sh` | Update your GitHub profile bio and prepend a migration notice to your profile README repo (`<user>/<user>`) | No (read/write your own profile) |
| `delete_codeberg_repos.sh` | Delete every repo owned by `CODEBERG_USERNAME` on Codeberg (useful for wiping a test run) | **Irreversible** — deletes from Codeberg |

A typical migration runs them in this order:

1. `migrate_github_to_codeberg.sh` — copy the repos
2. `migrate_issues_to_codeberg.sh` — copy issues/comments
3. `create_pr_references.sh` — leave historical pointers for PRs
4. `update_github_profile.sh` — point visitors at Codeberg
5. `mark_github_migrated.sh` — archive + signpost the GitHub originals
6. `delete_codeberg_repos.sh` — only when you want to wipe a **test** migration and start over

## Requirements

- `bash` 4.0+ (uses associative arrays / `${!array}` indirection)
- `curl` ([docs](https://curl.se/docs/))
- `jq` ([docs](https://jqlang.org/))

```sh
# Debian/Ubuntu
sudo apt install curl jq
# macOS
brew install curl jq
# Arch
sudo pacman -S curl jq
```

## Setup

Copy `.env.example` to `.env` and fill in your credentials:

```sh
cp .env.example .env
$EDITOR .env
```

Make the scripts executable (already committed executable, but to be safe):

```sh
chmod +x *.sh
```

### Generating tokens

- **GitHub:** [Managing personal access tokens](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens) — the mirror and archive steps require the `repo` scope.
- **Codeberg:** [Generating an access token](https://docs.codeberg.org/advanced/access-token/) — `write:repository` and `write:issue` are needed for repo/issue creation; `delete:repository` for the delete script.

### `.env` reference

| Variable                  | Req | Used by | Description |
|---------------------------|-----|---------|-------------|
| `GITHUB_USERNAME`         | yes | GH-side scripts | Your GitHub username |
| `GITHUB_TOKEN`            | yes | GH-side scripts | GitHub personal access token (`repo` scope) |
| `CODEBERG_USERNAME`       | yes | CB-side scripts | Your Codeberg username |
| `CODEBERG_TOKEN`          | yes | CB-side scripts | Codeberg access token |
| `FORGEJO_BASE_URL`        | no  | all | Target instance. Default: `https://codeberg.org`. Point at any Gitea/Forgejo host to mirror there |
| `REPOSITORIES`            | no  | most | Bash array of repo names to migrate. Empty = all repos you own |
| `OWNERS`                  | no  | most | Bash array of owner logins to filter by. Empty = all owners. Only applies when `REPOSITORIES` is empty |
| `DESCRIPTION_PREFIX`      | no  | migrate_repos | String prepended to each repo description. Default: `""` |
| `CODEBERG_REQUEST_DELAY`  | no  | most | Seconds to sleep between Codeberg API calls. Default: `2` |
| `MARK_REQUEST_DELAY`      | no  | mark | Seconds to sleep between GitHub repo updates. Default: `1` |
| `GITHUB_PAGE_SIZE`        | no  | all | Repos/issues fetched per GitHub API page. Max/default: `100` |
| `CODEBERG_PAGE_SIZE`      | no  | delete | Repos fetched per Codeberg API page. Max/default: `50` |
| `CURL_MAX_RETRIES`        | no  | all | Max retries on HTTP 429 before giving up. Default: `5` |
| `CURL_RETRY_AFTER_DEFAULT`| no  | all | Fallback wait (s) on 429 with no `retry-after` header. Default: `60` |
| `MIGRATION_NOTICE`        | no  | mark, profile | Banner text inserted into READMEs. |
| `MIGRATION_PREFIX`        | no  | mark | Prefix prepended to each archived repo's description. Default: `[ARCHIVED] Migrated to Codeberg: ` |
| `DISABLE_ISSUES`          | no  | mark | Disable issues on archived repos. Default: `true` |
| `DISABLE_PROJECTS`        | no  | mark | Disable projects on archived repos. Default: `true` |
| `DISABLE_WIKI`            | no  | mark | Disable wiki on archived repos. Default: `true` |
| `CREATE_PINNED_ISSUE`     | no  | mark | Create a pinned "we moved" issue on each archived repo. Default: `true` |
| `MIGRATE_CLOSED`          | no  | issues | Migrate closed issues too (not just open). Default: `true` |
| `MIGRATE_COMMENTS`        | no  | issues | Copy each issue's comments. Default: `true` |
| `PRESERVE_LABELS`         | no  | issues | Re-apply GitHub labels to Codeberg issues (missing labels skipped). Default: `true` |
| `PROFILE_BIO`             | no  | profile | New GitHub profile bio. Embed your Codeberg URL. Empty → skip bio update |
| `UPDATE_README`           | no  | profile | Prepend a migration banner to your profile README repo. Default: `true` |

## Usage

### 1. Migrate repositories

```sh
./migrate_github_to_codeberg.sh
```

Fetches all repositories from GitHub ([GET /user/repos](https://docs.github.com/en/rest/repos/repos#list-repositories-for-the-authenticated-user), paginated at 100) and mirrors them to Codeberg via the [migration API](https://codeberg.org/api/swagger#/repository/repoMigrate). Preserves name, description, and private/public status.

**Safety notices:**
- Your GitHub token is sent to the Codeberg API as part of the migration payload so Codeberg can pull the source repo. Use a token with the minimum required scope (`repo`) and revoke it when done.
- Private repositories are created as private on Codeberg, but verify after migration.
- Re-running reports a `409` conflict for any repo that already exists — safe to re-run.

Filter examples (set in `.env`):

```sh
REPOSITORIES=( "my-project" "dotfiles" )
OWNERS=( "myusername" "some-org" )
```

### 2. Migrate issues

```sh
./migrate_issues_to_codeberg.sh
```

Copies issues (open and/or closed, per `MIGRATE_CLOSED`) from each GitHub repo into the matching Codeberg repo, optionally re-applying labels and copying comments. Each migrated issue body begins with a link back to the original GitHub issue. Pull requests are skipped (see `create_pr_references.sh`).

### 3. Create PR references

```sh
./create_pr_references.sh
```

GitHub pull requests are git refs and can't be migrated as PRs. This script creates a **closed** Codeberg issue per GitHub PR that records the title, author, status (open/closed/merged), and body, with a link back to the original PR for historical tracking.

### 4. Update your GitHub profile

```sh
./update_github_profile.sh
```

Sets your GitHub profile bio to `PROFILE_BIO`, and (when `UPDATE_README=true`) prepends a migration banner to the README of your profile repo — the special repo named `<username>/<username>` whose README renders on your profile page.

### 5. Mark GitHub repos as migrated

```sh
./mark_github_migrated.sh
```

For each GitHub repo it:

1. Archives the repository
2. Updates the description to indicate the new Codeberg location
3. Prepends a migration notice banner to the README
4. Disables issues, projects, and wiki (configurable)
5. Creates a pinned "we moved" issue (configurable)

This makes the GitHub copies read-only and points visitors at Codeberg.

### 6. Delete all Codeberg repositories

```sh
./delete_codeberg_repos.sh
```

Deletes every repository owned by `CODEBERG_USERNAME` via the [Codeberg delete API](https://codeberg.org/api/swagger#/repository/repoDelete). Useful for wiping a test migration before re-running.

**Safety notices:**
- **This is irreversible.** Deleted repositories cannot be recovered.
- There is no per-repo confirmation — all repos are deleted after the initial ENTER.
- Org-owned repositories are not affected; only repos owned directly by `CODEBERG_USERNAME` are deleted.

## Selecting a subset of repositories

Every applicable script honors the same two filters from `.env`:

```sh
# Only these repos (by name)
REPOSITORIES=( "my-project" "dotfiles" )

# Only repos owned by these logins (applies when REPOSITORIES is empty)
OWNERS=( "myusername" "some-org" )
```

When `REPOSITORIES` is non-empty it always wins; `OWNERS` only filters the "all repos I own" list.

## Logging

Each run logs to stdout (errors go to stderr) — no log files are written.

## Limitations

The [migration API](https://codeberg.org/api/swagger#/repository/repoMigrate) does not transfer:

- Forks (mirrored as standalone repos)
- Issues and pull requests (use `migrate_issues_to_codeberg.sh` + `create_pr_references.sh`)
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

The script fetches repos in pages of 100 and makes one API call per page plus one call to `GET /user` for the total count. For most users this is well within the 5,000 req/hour primary limit. Rate limit status is returned in every response via `x-ratelimit-remaining` and `x-ratelimit-reset` headers. If you hit the limit GitHub returns `403` or `429` with a `retry-after` header. The scripts automatically back off on `429`.

> [GitHub rate limit docs](https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api)

### Codeberg (destination)

| Limit | Value |
|---|---|
| API rate limit (HAProxy layer) | ~2,000 requests / 300 seconds |
| `per_page` maximum | 50 items |
| **Repositories per user/org (default)** | **100** |
| Git storage per user/org | 750 MiB |
| LFS + packages + releases + attachments | 1.5 GiB additional |

**The 100-repo default cap is the most likely limit you will hit.** If you have more than 100 GitHub repositories, the migration will fail once the cap is reached. You can request an increase at [codeberg.org/Codeberg-e.V./requests](https://codeberg.org/Codeberg-e.V./requests) — increases to 500 or more are routinely granted.

The `/repos/migrate` endpoint is subject to the same 2,000 req/300 s HAProxy limit as all other Codeberg API calls. Migrations are processed asynchronously, so the API call returns immediately, but the underlying clone runs in the background. If a large migration gets stuck "in-progress", delete the repo from Codeberg settings to free the namespace and retry.

For large batches, adding a short delay between migration calls (e.g. `CODEBERG_REQUEST_DELAY=2`) is a community-recommended courtesy.

> [Codeberg rate limit issue](https://codeberg.org/Codeberg/Community/issues/425) · [Codeberg storage limits](https://blog.codeberg.org/new-storage-limits-on-codeberg-what-you-need-to-know.html) · [Request a quota increase](https://codeberg.org/Codeberg-e.V./requests)

## API reference

- [GitHub — GET /user](https://docs.github.com/en/rest/users/users#get-the-authenticated-user)
- [GitHub — PATCH /user](https://docs.github.com/en/rest/users/users#update-the-authenticated-user)
- [GitHub — GET /user/repos](https://docs.github.com/en/rest/repos/repos#list-repositories-for-the-authenticated-user)
- [GitHub — List repository issues](https://docs.github.com/en/rest/issues/issues#list-repository-issues)
- [GitHub — List pull requests](https://docs.github.com/en/rest/pulls/pulls#list-pull-requests)
- [GitHub — Get a README](https://docs.github.com/en/rest/repos/contents#get-a-repository-readme)
- [GitHub — Create/Update file contents](https://docs.github.com/en/rest/repos/contents#create-or-update-file-contents)
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

## License

See [LICENSE](LICENSE).