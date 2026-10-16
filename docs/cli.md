# Collaboration CLI

The native `moonhub` executable also acts as a remote collaboration client.
`auth`, `mr`, `issue`, `ci` and `inbox` connect to the Web service through
`/-/api/v1`. They do not open the server database. Existing Web startup,
Runner/provider and administration commands retain their entry points.

## Authentication

Create an access token in **Account menu > Access tokens** (`/-/settings/tokens`).
Give it a name, permission and an expiry of 1–365 days (default 30). The secret
is displayed only in the creation response; list pages never display it again.
The database stores its SHA-256 hash. Each account supports up to 20 active tokens.
Token authentication rechecks active account state, expiry, revocation and current
repository permissions on every request. Revoke a token from the same settings page.
Successful password recovery revokes every access token for that account alongside
its existing sessions. Other accounts' tokens remain valid.

| Permission | Allows |
| --- | --- |
| `read` | View MR/Issue/run/Inbox data and CI logs |
| `write` | Read plus collaboration mutations, reviews and marking notifications read |
| `execute` | Write plus starting/rerunning/cancelling CI and approving MR check execution |
| `merge` | Write plus submitting an MR merge |

Execution and merge permissions are independent. Tokens do not grant repository
roles: a contributor with a merge token still cannot merge without existing
manager authorization. Required approvals and version-bound checks still apply.
MR creation through a write token does not implicitly approve execution; use an
execute token for **approve-checks**. Existing authorization from an actual manager
Git push remains valid under the MR check policy.

Save the token to a private file, then sign in:

```sh
chmod 600 /path/to/moonhub.token
moonhub auth login --server https://moonhub.example --token-file /path/to/moonhub.token
moonhub auth status
moonhub auth logout
```

Login verifies the token before saving it under
`$XDG_CONFIG_HOME/moonhub/auth.json`, or `$HOME/.config/moonhub/auth.json`.
An unset or empty `XDG_CONFIG_HOME` falls back to `$HOME/.config`.
The directory uses mode 0700 and the file 0600; login replaces the file atomically.
Explicit server and token credentials bypass saved state, so login can repair a
damaged credential file without first reading it.
This is a plaintext credential file, so keep it private. Logout removes the local
file; server revocation remains a separate action.

For automation, use `MOONHUB_SERVER` and `MOONHUB_TOKEN`, or `--token-file`, without
saving credentials. Tokens are never accepted as command-line values. Saved tokens
are used only for their saved server origin. HTTPS is required by default;
`--allow-http` explicitly enables trusted local development. Redirects are rejected,
not followed with credentials. Requests have a 30-second deadline and bounded
responses. Browser session cookies cannot authenticate the JSON API.

## Repository and output

Use `--repo OWNER/NAME` or `MOONHUB_REPOSITORY`. When omitted, the client checks
`origin` push URLs first, then the fetch URL, and accepts only a remote whose host
matches the configured server. It supports SSH URLs, SCP-style Git URLs and HTTP
Git URLs. It does not infer another server from a Git remote or change remotes.

Add `--json` for machine-readable output. Resource IDs, versions and cursors are
canonical decimal strings, avoiding JSON integer precision loss. List commands
accept `--page` where supported; MR/Issue/Inbox pages contain at most 50 entries.
CI lists use the server's existing latest-run limit. Human-readable lists strip
terminal control characters from repository content.

## Commands

```sh
moonhub mr list --repo compiler/moonhub
moonhub mr create --source feature --target master --title 'Add checks' --body-file description.md
moonhub mr view 4 --json
moonhub mr diff 4 --version 1 --json
moonhub mr checks 4 --json
moonhub mr comment 4 --version 1 --body-file comment.md
moonhub mr edit 4 --edit-version 1 --title 'Updated title' --body-file description.md
moonhub mr delete-comment 4 --comment 42 --version 1
moonhub mr restore-comment 4 --comment 42 --version 1
moonhub mr review 4 --version 1 --decision approved
moonhub mr request-review 4 --version 1 --reviewer 12
moonhub mr approve-checks 4 --version 1
moonhub mr merge 4 --version 1
moonhub mr close 4 --edit-version 1

moonhub issue list --status open
moonhub issue create --title 'Track work' --body-file issue.md --assignee 12
moonhub issue view 2 --json
moonhub issue comment 2 --body-file reply.md
moonhub issue close 2 --edit-version 1
moonhub issue reopen 2 --edit-version 2
moonhub issue edit 2 --edit-version 3 --title 'Updated' --body-file issue.md --assignee 12

moonhub ci list
moonhub ci run --branch master --workflow .github/workflows/moonhub.yml
moonhub ci view 9 --json
moonhub ci logs 9 --attempt 14 --after 0 --json
moonhub ci cancel 9
moonhub ci rerun 9

moonhub inbox --filter reviews --json
moonhub inbox list --filter assigned
moonhub inbox read 25
```

MR review decisions are `approved`, `changes_requested`, `withdrawn` or `comment`.
`mr edit` requires `--edit-version` and at least one of `--title` or `--body-file`.
Omitted fields are preserved; an empty body file explicitly clears the description.
Editing metadata does not refresh branches, create a revision, or reset approvals
and checks. The author or a repository team administrator may edit metadata.

`mr view --json` activity entries include stable decimal-string `id` and `actor_id`
(empty for system activity). Use a plain comment's `id` as `--comment`, and its
own `version` as `--version`, including for a comment on an older MR revision.
Delete/restore requires a write token and either comment authorship or team
administrator permission. Other members cannot delete another author's comment.
Review decisions and lifecycle events cannot be deleted with these commands.
Deletion replaces the public body with an empty `comment_deleted` tombstone;
the original body is retained in the private repository audit for explicit restore.
Repeated delete or restore requests are idempotent. These operations do not
change approvals, checks, or the MR's metadata edit version.

MR state actions also include `draft`, `ready` and `reopen`, each requiring
`--edit-version`. Mutation versions are explicit: the client never automatically
submits a review or merge against a version the user did not select. Reload the
MR/Issue after a stale-version response before retrying.

Descriptions/comments use `--body-file` (regular UTF-8 file, at most 20,000 bytes).
Reviewer and assignee values are account IDs, not display names. `auth status`
shows your account ID; `mr view --json` includes eligible reviewer IDs. `issue edit`
requires at least one of `--title`, `--body-file` or `--assignee`, and preserves
omitted fields. Use an empty body file to clear the description and `--assignee 0`
to remove the assignee. Log responses expose `next_cursor`, `has_more`
and `complete`; request subsequent pages with `--after`. No background watch or
automatic retry of mutations is performed.

Exit codes: 0 for success/help, 1 for HTTP/transport/response failures, 2 for invalid
CLI input. The API returns stable JSON error codes and no-store responses, and
redacts unexpected server/Git errors. Creating/reviewing/merging through the API
uses the same business services and per-repository write locks as the browser.

## Upgrade and verification

Migration 016 adds tokens without changing accounts, sessions or existing jobs.
Build/Runner defaults use MoonBit `0.10.15+943464bfa`, matching the October 12
formatter commit; rebuild the dependency base and Runner for this release.
Upgrade matching Web/SSH executables together. Token credentials are excluded
from identity-only exports; create replacement credentials on a migrated site.

```sh
moon check --deny-warn
moon fmt
moon info
moon test --strip -j 1
node scripts/check-package-boundaries.cjs
moon build --strip -j 1
node scripts/cli-smoke.cjs
```

The smoke uses a disposable local service, repository/database, private token
files and a file mail outbox. It tests real CLI login, token revocation, MR/Issue
mutations, review/merge permissions, CI controls and Inbox, and captures desktop
and mobile token settings. It requires Node with `node:sqlite` and Playwright on
its module search path. Evidence remains under `_build/cli-smoke`; it never uses
production accounts or runs submitted workflow scripts.
