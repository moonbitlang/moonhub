# hackwaly/moonhub

## Docker and Git SSH

Run HTTP and Git-over-SSH services with Docker Compose. See
[Docker deployment](deploy/README.md) for bootstrap secrets, key registration,
repository creation/import, persistence, and the end-to-end smoke test.

Repositories must be registered in the database before authenticated users can
access them. The same repository permissions apply to SSH and browser access.
Signed-in users can add, inspect, and revoke their own SSH keys from the
**SSH keys** link in the site header (`/settings/ssh-keys`).
Team owners and admins can create repositories or import them over SSH from the
team page. Creation runs in the background, with status and retry controls;
[configure a team's import identity and trusted source hosts](deploy/README.md#ssh-import)
before importing private repositories.

## Browser Assets

The rich code views are built from the JavaScript project under `js/` and
emitted into the repository `assets/` directory:

```sh
cd js
npm install
npm run build
```

Run the build again after changing files under `js/src/`. The MoonBit server
reads the configured assets directory's `.vite/manifest.json` to load the hashed
`custom-elements` bundle. The manifest is required; public files served from
`/assets/` are treated as immutable build artifacts, and `.vite/manifest.json`
is not served publicly.

The top-level owner name `assets` is reserved for browser assets, so repositories
under `assets/*.git` are intentionally ignored by the repository browser.

## Manual Testing

The server uses SQLite by default. Copy the example environment file before
starting the server:

```sh
cp .env.example .env
# Edit DB_PATH in .env if you want to store the database elsewhere.
```

The server creates the SQLite database and schema automatically on first start.

Use the tracked test fixture under `testdata/repos`:

```sh
moon run . -- testdata/repos --assets ./assets --host 127.0.0.1 --port 8080 --root-password change-me
```

After activating the root account, create an `alice` team and register the fixture:

```sh
moon run . -- repo-create alice/demo --root testdata/repos --import
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

Invitation emails are queued in `email_outbox` and delivered by the background
mail worker. The default development transport writes `.eml` files to
`_build/mail_outbox`:

```sh
MAIL_TRANSPORT=file
MAIL_OUTBOX_DIR=_build/mail_outbox
```

Set `MAIL_TRANSPORT=smtp` to send through SMTP:

```sh
MAIL_TRANSPORT=smtp
SMTP_HOST=smtp.example.com
SMTP_PORT=587
SMTP_SECURITY=starttls
SMTP_AUTH=plain
SMTP_USERNAME=mailer@example.com
SMTP_PASSWORD=app-password
SMTP_FROM=noreply@example.com
```

`SMTP_SECURITY` supports `plain`, `starttls`, and `tls`. `SMTP_AUTH` supports
`none`, `plain`, `login`, and `xoauth2`.
