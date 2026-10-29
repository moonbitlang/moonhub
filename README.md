# hackwaly/moonhub

The native executable includes a remote collaboration CLI: `auth`, `mr`,
`issue`, `ci` and `inbox`. Create an access token in Account settings and see
[CLI setup and commands](docs/cli.md).

AI clients can use the native [MCP 2.0 endpoint](docs/mcp.md) at `/-/mcp`
(protocol revision 2026-07-28), authenticated with the same scoped access tokens.

Repository collaboration includes Issues and same-repository Merge Requests.
Branch protection can require existing Pipeline workflows to pass against the
merged source/target tree. See [MR Pipeline checks](docs/merge-checks.md) for
setup, execution approval, version-bound results, and upgrade requirements.
See [collaboration architecture and supported behavior](docs/collaboration.md).
Descriptions and comments support [managed Markdown image attachments](docs/attachments.md),
including browser uploads and CLI inline image conversion.
Repository managers can configure [push mirrors](docs/mirrors.md) to sync
branches and tags to an SSH remote such as GitHub.
Repository managers can configure [signed Webhooks](docs/webhooks.md) for Push,
Issue, MR, review and Pipeline events, with retry and delivery history.
Request reviewers from an MR discussion and use **Inbox** for pending reviews,
assigned Issues and collaboration updates. Email reminders are optional. See
[review requests and notifications](docs/notifications.md).
See [package boundaries, dependency injection and tests](docs/architecture.md)
for the source layout and module initialization rules.

Pipeline implementation is staged. Workflow validation, immutable run snapshots,
an authenticated runner protocol, and a single-job Runner are implemented.
Docker provider, bounded source checkout, standard `pull_request` triggers and
the built-in checkout action and captured run-context references in `env` are
available; full GitHub Actions compatibility is
not yet implemented. See
[the supported subset and delivery plan](docs/pipelines.md).

## Browser frontend

The browser uses Rabbita with native server-side rendering and client hydration.
Direct URLs return a complete page; subsequent same-origin page navigation and
ordinary forms update the Rabbita view without replacing the document. Pages
remain usable through native links and forms when JavaScript is unavailable.
See [SSR, hydration and browser tests](docs/frontend.md) for the current migration
boundary and development workflow.

## Docker and Git SSH

Run HTTP and Git-over-SSH services with Docker Compose. See
[Docker deployment](deploy/README.md) for bootstrap secrets, key registration,
repository creation/import, persistence, and the end-to-end smoke test.

Repositories must be registered in the database before authenticated users can
access them. The same repository permissions apply to SSH and browser access.
Signed-in users can add, inspect, and revoke their own SSH keys from the
**SSH keys** link in the site header (`/-/settings/ssh-keys`), and change their
display name from **Profile** (`/-/settings/profile`). Usernames identify
repository namespaces, so they are fixed for the life of the account.
Site administrators reach **Site settings** (`/-/admin/settings/ssh`) from the
**Administration** group in the sidebar of any page, or from the site header
account menu, and configure the client-facing hostname and port there.
Repository pages provide a
**Clone** menu with the public SSH URL and a copy button; container-internal
transport addresses remain separate.
If the configured default branch has no commit, file and history pages fall
back to an available branch (`main`, `master`, then name order), or a commit
tag when no branch is available. Browsing never changes Git HEAD or selects
private pipeline/merge retention refs. An explicitly requested missing revision
still returns 404; repositories without a browsable commit show empty pages.
Every repository belongs to a namespace, and every namespace has its own page at
`/<name>`: a user's personal namespace, or an organization team. Team owners and
admins create or import repositories there, and the page lists the existing
ones. Pages that are not repositories live under the reserved `/-/` prefix, so
any name is available to a namespace.
Activating an account creates its personal namespace, so **New repository** on
the repositories page creates a repository under the user's own name. Creation
runs in the background, with status and retry controls;
[configure a team's import identity and trusted source hosts](deploy/README.md#ssh-import)
before importing private repositories.

## Browser Assets

The rich code views are built from the JavaScript project under `js/` and
emitted into the repository `assets/` directory. Build them from the module
root after cloning, before running the local server or the MoonBit Web tests:

```sh
npm ci --prefix js
npm run build --prefix js
```

`assets/` (including its Vite manifest) and `js/src/icons.generated.css` are
generated files ignored by Git. Keep the frontend sources, icon generator and
`js/package-lock.json` in version control; `npm run build` regenerates both
outputs. CI and Docker build the assets from source before tests or packaging.

Run the build again after changing frontend sources or dependencies. The MoonBit
server reads the configured assets directory's `.vite/manifest.json` to load the hashed
`custom-elements` bundle. The manifest is required; public files served from
`/assets/` are treated as immutable build artifacts, and `.vite/manifest.json`
is not served publicly.

The top-level owner name `assets` is reserved for browser assets, so repositories
under `assets/*.git` are intentionally ignored by the repository browser.

## Manual Testing

### Temporary Compiler Workaround

Until a verified compiler fix is available, use `--strip -j 1` for native
development builds, tests, and runs:

```sh
moon build --strip -j 1
moon test --strip -j 1
```

With `moonc v0.10.12+ef027fb8a` (2026-09-11), local profiling found excessive
CPU time in the new native backend's debug-location generation. Removing only
`-g` reduced the same cached-input code-generation step from more than 20 seconds
to about 5 seconds. `--strip` omits source-level debugger information while
keeping the normal debug build's `-O0`; `-j 1` limits concurrent build jobs.
This does not change application behavior or require release mode. Type checks,
formatting, and production release builds do not need this workaround.

After upgrading MoonBit, verify that an unstripped native build and the full
test suite complete promptly before removing `--strip` from development
commands, the self-check script, and `AGENTS.md`. A new version alone is not
confirmation that the issue is fixed.

### Local Server

The server uses SQLite by default. Copy the example environment file before
starting the server:

```sh
cp .env.example .env
# Edit DB_PATH in .env if you want to store the database elsewhere.
```

The server creates the SQLite database and schema automatically on first start.

Use the tracked test fixture under `testdata/repos`:

```sh
moon run --strip -j 1 . -- testdata/repos --assets ./assets --host 127.0.0.1 --port 8080 --root-password change-me
```

After activating the root account, create an `alice` team and register the fixture:

```sh
moon run --strip -j 1 . -- repo-create alice/demo --root testdata/repos --import
```

Then open these pages in a browser:

- <http://127.0.0.1:8080/>
- <http://127.0.0.1:8080/alice/demo>
- <http://127.0.0.1:8080/alice/demo/tree/master>
- <http://127.0.0.1:8080/alice/demo/blob/master/README.md>
- <http://127.0.0.1:8080/alice/demo/blob/master/src/main.mbt>
- <http://127.0.0.1:8080/alice/demo/commits>

To inspect a commit page, get the fixture commit hash first:

```sh
git --git-dir=testdata/repos/alice/demo.git rev-parse master
```

Then open:

```text
http://127.0.0.1:8080/alice/demo/commit/<commit-hash>
```

Press `Ctrl-C` in the terminal running `moon run` to stop the server.

## Email Delivery

Sign in using either your username or full account email address. Email matching
ignores case and surrounding whitespace; passwords remain case-sensitive and are
not trimmed. Pending invitees can also sign in with their invitation email and
one-time password, then set a permanent password to activate the account.

When an invitee cannot receive email, a site administrator (the root role) can
open **Teams > team > Invitations > View sign-in details** to retrieve the
original invitation email, including its one-time password and expiry time.
Team owners, team admins, and members cannot view these credentials. Only
unaccepted, unrevoked, unexpired invitations with a stored email are available;
users' permanent passwords are never shown. Details are fetched only on an
explicit, CSRF-protected action and are returned with `Cache-Control: no-store`.

### Password Recovery

Choose **Forgot password?** on the sign-in page (`/-/forgot-password`) and enter
the email associated with an active account. Enter the emailed reset code and a
new password at `/-/reset-password`. Codes are single-use and expire after 30
minutes; successful recovery revokes all existing login sessions and reset codes.
The account also receives a password-change notification.
Requests return the same message for unknown, disabled, and throttled accounts.
Each account can receive at most one code per minute and five per hour. Pending
invitations must still use their invitation credentials; accounts without a
deliverable email cannot use email recovery.

Recovery uses the configured mail transport below, not a separate email service.
Only code hashes are kept in `password_reset`; queued mail necessarily contains
the code until delivery, when it is removed from the database outbox body. The
file transport retains its `.eml` files, so protect those files like credentials.

### Transport

Invitation and password recovery emails are queued in `email_outbox` and delivered
by the background mail worker. The default transport writes `.eml` files to
`_build/mail_outbox`:

```sh
MAIL_OUTBOX_DIR=_build/mail_outbox
```

To send real email, open **Site settings > Email delivery** in the sidebar as a
site administrator and select **SMTP**. Configure the host, port, security mode,
authentication,
credentials, and sender address there. The password is stored in the database,
is never rendered back into the form, and can be retained by leaving the
password field blank when saving changes.

Saved settings take effect for subsequent deliveries without restarting the
server. `MAIL_TRANSPORT` and `SMTP_*` environment variables are no longer read;
existing deployments must enter their SMTP settings in the web UI after
upgrading. Until then, delivery defaults to the file outbox. Protect the SQLite
database and its backups: SMTP credentials are stored as plaintext, not hashed,
because the mail worker needs them for authentication.

SMTP security supports `plain`, `starttls`, and `tls`. Authentication supports
`none`, `plain`, `login`, and `xoauth2`.
