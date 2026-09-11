# hackwaly/moonhub

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

The server requires PostgreSQL. Create a local database and role, then copy
the example environment file before starting the server:

```sh
cp .env.example .env
# Edit .env if your PostgreSQL connection differs from the example.
```

Make sure the database named in `PG_URL` is running and reachable. The server
creates its schema automatically on first start.

Use the tracked test fixture under `testdata/repos`:

```sh
moon run . -- testdata/repos --assets ./assets --host 127.0.0.1 --port 8080 --root-password change-me
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
