# Collaboration CLI

The native `moonhub` executable also acts as a remote collaboration client.
`auth`, `mr`, `issue`, `ci`, `secret` and `inbox` connect to the Web service through
`/-/api/v1`. They do not open the server database. Existing Web startup,
Runner/provider and administration commands retain their entry points.

These commands document the MoonHub product. Development and CI for this source
repository use GitHub; see [repository CI and migration](github-ci.md). Workflow
examples below refer to files in the repository being operated on.

## Authentication

With a current MoonBit toolchain installed, run the published Wasm client directly:

```sh
moonx hackwaly/moonhub/cmd/moonhub@latest --help
moonx hackwaly/moonhub/cmd/moonhub@latest auth setup --server https://moonhub.example
moonx hackwaly/moonhub/cmd/moonhub@latest auth login \
  --server https://moonhub.example --token-file /path/to/moonhub.token
moonx hackwaly/moonhub/cmd/moonhub@latest auth status --json
moonx hackwaly/moonhub/cmd/moonhub@latest mr list --repo OWNER/NAME
```

For the shorter commands below, Bash and Zsh users can define:

```sh
alias moonhub='moonx hackwaly/moonhub/cmd/moonhub@latest'
```

`@latest` refreshes the registry version; use `@0.1.1` for a reproducible version.
Running without arguments or with `--help` shows setup instructions. When the
server or token is missing, the client explains how to create an access token,
sign in and verify the saved credentials; a configured server supplies the
concrete token-settings URL.
For a trusted local HTTP server, pass `--allow-http` to `auth setup`; the
generated login and verification commands retain that option. HTTPS setup
does not suggest enabling HTTP.
Every subcommand has focused options and examples in `--help`; for example,
`moonhub mr merge --help` explains where to obtain the required revision and how
to inspect the issues that a merge will close. `moonhub --version` (or `-V`)
prints the client release; subcommands use `--version VALUE` for resource revisions.
The client uses the same credentials, environment variables, commands and exit
codes as the native `moonhub` executable used in the examples below. Git must be
installed when inferring `--repo` from the current repository; pass `--repo` to
select a repository explicitly. The published entry point is a remote client;
server, runner and administration commands use the native executable.

To build and check the client from source:

```sh
moon build --target wasm --strip -j 1 --deny-warn cmd/moonhub
moon test --target wasm --strip -j 1 --deny-warn cli domain
node scripts/cli-wasm-smoke.cjs
```

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
The CLI does not push MR branches. Use Git to push to the product repository's
configured SSH remote before creating an MR. Development of MoonHub itself uses
the GitHub remote described in [repository CI](github-ci.md).

Add `--json` for machine-readable output. Resource IDs, versions and cursors are
canonical decimal strings, avoiding JSON integer precision loss. List commands
accept `--page` where supported; MR/Issue/Inbox pages contain at most 50 entries.
CI lists use the server's existing latest-run limit. Human-readable lists strip
terminal control characters from repository content.

`ci run --jobs build,test` selects original logical job IDs and their complete
dependency closure, including all matrix children. Explicit selection lets a
repository manager run a PR-only workflow without adding `workflow_dispatch` or
changing Git refs. Omitting `--jobs` retains the normal dispatch requirement.
The saved source YAML and commit are unchanged; reruns retain the selected plan.
The REST run request accepts the same selection as a `jobs` array. Browser Run
workflow offers a Job selector. Existing execute-token and manager authorization
remain required; selecting jobs never satisfies or reruns an MR's required check.

## Commands

```sh
moonhub mr list --repo compiler/moonhub
moonhub mr create --source feature --target master --title 'Add checks' --body-file description.md
moonhub mr view 4 --json
moonhub mr diff 4 --version 1 --json
moonhub mr checks 4 --json
moonhub mr comment 4 --version 1 --body-file comment.md
moonhub mr discussions 4 --filter unresolved --json
moonhub mr reply 4 --discussion 42 --body-file reply.md
moonhub mr resolve-discussion 4 --discussion 42 --state-version 1
moonhub mr reopen-discussion 4 --discussion 42 --state-version 2
moonhub mr edit 4 --edit-version 1 --title 'Updated title' --body-file description.md
moonhub mr edit 4 --edit-version 2 --target release/stable
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
moonhub ci run --branch master --workflow .github/workflows/build.yml
moonhub ci run --branch main --workflow .github/workflows/ci.yml --jobs tui-windows
moonhub ci run --branch master --workflow .github/workflows/release.yml \
  --inputs-file /absolute/path/inputs.json
moonhub ci view 9 --json
moonhub ci logs 9 --attempt 14 --after 0 --json
moonhub ci cancel 9
moonhub ci rerun 9

moonhub secret list --repo compiler/moonback --json
moonhub secret set MOONCAKES_MOONBITLANG_TOKEN --repo compiler/moonback \
  --branch master --workflow .github/workflows/publish.yml \
  --body-file /private/path/credentials.json --version 0
moonhub secret set MOONCAKES_MOONBITLANG_TOKEN --repo compiler/moonback \
  --branch master --workflow .github/workflows/publish.yml \
  --body-file /private/path/replacement.json --version <current-version>
moonhub secret delete MOONCAKES_MOONBITLANG_TOKEN --repo compiler/moonback \
  --version <current-version>

moonhub inbox --filter reviews --json
moonhub inbox list --filter assigned
moonhub inbox read 25
```

MR review decisions are `approved`, `changes_requested`, `withdrawn` or `comment`.
`mr edit` requires `--edit-version` and at least one of `--title`, `--body-file`
or `--target`. Omitted fields are preserved; an empty body file explicitly clears
the description. Editing only title/description does not refresh branches, create
a revision, or reset approvals and checks. The author or a repository team
administrator with repository write access may edit.

Changing `--target` is allowed only for open MRs (including drafts), while no merge
is queued or running. The branch must exist, differ from the source and leave new
source commits; another open MR must not already use the same source/target pair.
A changed target always creates a new comparison version, even when both target
branches point to the same commit. Reviews and check results from the old version
no longer count, requested reviews become pending for the new version, and checks
are selected using the new target's protection rules. Plain write requests do not
grant CI execution permission. Repeating the current target is a no-op unless
metadata changes. Combined metadata and target edits commit atomically.

The API accepts `target` on `POST /-/api/v1/repos/:owner/:repo/mrs/:number/edit`
with the observed `edit_version`. Historical diff responses include `target`,
the branch name saved with that comparison version.

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

The MR diff command accepts an optional full lowercase commit SHA:

```sh
moonhub mr diff 4 --version 1 --commit <full-commit-sha> --json
```

Without `--commit`, the diff compares the selected version's merge base and
source. With `--commit`, it compares an MR commit to its first parent (also for
merge commits); parentless imported commits compare with the empty tree. The
commit must belong to that saved version's source-minus-target range and name a
commit object directly (annotated tag, tree and blob IDs are rejected). JSON
retains `version`/`source_sha`/`target_sha` and adds `comparison` (`all` or
`commit`), `base_sha`/`head_sha`, nullable `commit_sha` and `parent_count`; the
latter is zero for an all-changes comparison. The required `--version` keeps
historical comparisons explicit.

Create an inline discussion on a displayed line or range in an MR comparison:

```sh
moonhub mr inline-comment 4 --version 1 --path src/main.mbt \
  --side new --start-line 12 --body-file comment.md
moonhub mr inline-comment 4 --version 1 --commit <full-commit-sha> \
  --path src/main.mbt --side old --start-line 12 --end-line 16 \
  --body-file comment.md
```

`--version` is required. Omit `--commit` for All changes, or pass the full
lowercase SHA of a commit in the saved version. `--side` is `old` or `new`;
`--path` must match that side's path. `--end-line` defaults to `--start-line`.
The inclusive range must contain 1–100 consecutive displayed lines within one
hunk on one side. Binary files, pure renames and absent diff positions are
rejected. Creation requires a write token and repository contributor access.

The API endpoint is `POST /-/api/v1/repos/:owner/:repo/mrs/:number/inline-comment`.
Its JSON fields are strings: `version`, optional `commit`, `path`, `side`,
`start_line`, `end_line` and `body`. Unlike the CLI option, API `end_line` is
required even for one line. Omitted or empty `commit` selects All changes.

Inline discussions retain their saved version, comparison, base/head object IDs,
old/new paths, side, line range and code context after source updates. They use
the same reply, resolve/reopen and delete/restore commands as other discussions.
Discussion JSON has a nullable `anchor`; anchored lists preview up to 512 Unicode
scalars of saved `context` with `context_truncated`. A single-discussion read
returns the complete saved snippet, whose code lines are capped at 120 scalars
plus an ellipsis when truncated. Notification links restore the anchored
historical Changes view. Reviews still apply to the entire MR version.

MR discussions have stable decimal-string IDs. A discussion is rooted in an
existing comment or review body and keeps the revision where it was opened.
Replies may be added to an older revision and do not reopen a resolved discussion.
The `mr discussions` command accepts `--filter all|unresolved|resolved`;
pass `--discussion <id>` to inspect one thread. Resolving and reopening require
`--state-version`, which is checked atomically so stale UI actions fail instead
of overwriting a newer state. Discussion authors, MR authors and team
administrators may resolve or reopen; repository contributors may reply.
Discussion state changes and replies follow existing MR notification subscriptions. Resolve does not withdraw a
changes-requested review and unresolved discussions do not block merging.

Lists return 50 discussions plus a has-more flag; each list item previews up to
three recent replies. List bodies are previews of at most 512 Unicode scalar
values, with `body_truncated` indicating omitted content. Inspect one discussion
with `--discussion` and use `--page` to read all replies chronologically,
50 at a time. The reply response includes the new decimal-string `reply_id`. State changes return the new `state_version`. Deleting
or restoring a root/reply keeps discussion membership, reply history and resolve
state intact. Closed and merged MRs remain available for discussion.
Inbox entries expose `discussion_id`/`comment_id` when present; their URLs locate
the exact discussion/comment even after it moves beyond the first page.

MR state actions also include `draft`, `ready` and `reopen`, each requiring
`--edit-version`. Mutation versions are explicit: the client never automatically
submits a review or merge against a version the user did not select. Reload the
MR/Issue after a stale-version response before retrying.

To close issues when an MR successfully merges, include `Closes #123`,
`Fixes #123` or `Resolves #123` in the description passed via `--body-file` to
`mr create` or `mr edit`. Example `description.md`:

```text
Fix the save failure.

Closes #123, #124
```

Inspect `moonhub mr view 4 --json` before merging: `mr.closing_issue_numbers`
lists the parsed issue numbers as decimal strings. Create/edit/list responses
also include `closing_issue_numbers` on each MR object. Adding/removing directives
through `mr edit --body-file description.md --edit-version N` changes the eventual
closures. Keywords are case-insensitive; only same-repository `#N` references in
the description count. Titles, comments and code examples do not count. A related
issue link alone does not close an issue. Missing/already closed issues are skipped,
and failed merges or closing an unmerged MR leave issues open. Check issue
status/activity after the merge worker completes; submitting a merge only queues
it. For a nonempty declaration, merge with both observed versions, for example
`moonhub mr merge 4 --version 1 --edit-version 2`. Missing or stale metadata
confirmation is rejected; reload the MR before retrying. See
[closing directives](collaboration.md#issues) for full syntax and lifecycle.

Descriptions/comments use `--body-file` (regular UTF-8 file, at most 16 MiB).
Inline Markdown images using `data:image/png;base64,...` (also JPEG, GIF and WebP)
are stored by the server and rewritten to managed image URLs. Each image is at
most 5 MiB, inline images total at most 10 MiB per field, and the final Markdown
must fit 20,000 characters with at most eight managed attachments.
Use `moonhub attachment upload --file /path/to/file --repo compiler/moonhub`
for standalone uploads (images up to 5 MiB; other files up to 25 MiB). It prints
Markdown to insert into a body file; `--json` returns metadata and the same
`markdown` field. Files become download links and recognized images become
embedded images. See [attachments](attachments.md) for permissions and retention.
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

## Repository secrets

Secret operations additionally require repository owner/admin access. A read
token can list metadata; a write token can save or delete. Values are never
returned. `secret set` accepts a regular UTF-8 `--body-file` of at most 16 KiB,
preserving its exact contents. Never pass the value directly as an argument.
Version `0` creates a secret; update/delete use its current decimal-string
version from `secret list`. Omitting the body file preserves an existing value.
Both `--branch` and `--workflow` are required when saving. See
[repository secrets](pipelines.md#repository-secrets) for execution and masking.

The JSON API uses `GET /repos/:owner/:repo/secrets` for metadata,
`POST /repos/:owner/:repo/secrets/:name` with string fields `branch`, `workflow`,
`version` and optional `value`, and
`POST /repos/:owner/:repo/secrets/:name/delete` with string `version`.
All paths are relative to `/-/api/v1`; responses have `Cache-Control: no-store`.

## Webhooks

The webhook subcommands manage signed repository integrations, test events,
delivery history and retries. See [Webhook CLI/API](webhooks.md#cli-and-api) for
the private JSON configuration format and full command list. Repository manager
access is required in addition to token permission.

## Upgrade and verification

The baseline schema includes access tokens, accounts, sessions and jobs. The
Build/Runner compiler pin is defined in `deploy/base.Dockerfile`; see the
[current toolchain requirements](../README.md#moonbit-toolchain). Rebuild the
dependency base and Runner when changing that deployment pin. Upgrade matching
Web/SSH executables together. Preserve credentials through complete deployment
backups; see [database compatibility](../db/README.md).

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

## Repository variables

The `variable list/set/delete` commands manage readable, non-secret string
configuration. Values are supplied through a regular UTF-8 `--body-file` (up to
48 KiB; empty files are allowed). Create with `--version 0`; updates/deletes use
the current version. See [repository variables](repository-variables.md) for
permissions, limits, API routes and immutable execution snapshots.
