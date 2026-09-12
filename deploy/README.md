# Docker Deployment

The Compose deployment runs the same image in two services:

- `web`: MoonBit HTTP server, running as the unprivileged `git` user.
- `ssh`: OpenSSH, with a privileged listener and unprivileged Git sessions.

The `data` volume contains repositories, SQLite (including its WAL files), and
file-transport invitation emails. The separate `ssh-host-keys` volume contains
the SSH server identity. Neither volume is replaced by an image rebuild.

## Start

Requirements: Docker Engine/Desktop with Docker Compose v2 or later. The optional
smoke test requires Compose 2.24.4 or later for its port overrides, plus Bash,
curl, Git, and OpenSSH client tools on the host.

From the repository root, create a bootstrap secret **once**:

```sh
mkdir -p deploy/secrets
(umask 077; openssl rand -base64 32 > deploy/secrets/root_password)
docker compose up -d --build --wait
```

Open `http://localhost:8080`, sign in as `root` using the contents of
`deploy/secrets/root_password`, and set a new password. This activates the account
and creates its personal `root` namespace. The bootstrap password is not a Docker
build argument, is not included in the image, and is passed to the application
through a restricted runtime file rather than a command-line argument.

The secret file is ignored by Git and excluded from the Docker build context.
Keep it available for subsequent Compose starts. Replacing it does not reset an
already activated administrator account.

The image builds browser assets with `npm ci`, runs the MoonBit tests, and compiles
the native executable on Linux. No host MoonBit or Node installation is needed. The build
argument `MOONBIT_VERSION` can select an archived MoonBit toolchain release;
its default is `latest`.

## Bind a Public Key

The first version accepts OpenSSH **Ed25519** user keys. Private keys remain on
the client. Users must have activated their account by accepting their invitation
before a key can be registered. Key administration is currently operator-only
through the container CLI; there is no SSH-key settings page yet.

```sh
docker compose exec -T --user git web moonhub ssh-key-add root \
  --title laptop < ~/.ssh/id_ed25519.pub
docker compose exec --user git web moonhub ssh-key-list --user root
```

The add command prints the numeric key ID, username, and SHA256 fingerprint.
Revoke a key by its ID:

```sh
docker compose exec --user git web moonhub ssh-key-revoke 1
```

Revocation and account disabling reject new SSH connections and new Git commands
on an existing multiplexed connection. They do not forcibly terminate a transfer
that is already running. Revoked keys remain reserved in the database; register
a newly generated key rather than reusing a revoked one.

## Create or Import a Repository

Create a private bare repository in an existing namespace:

```sh
docker compose exec --user git web moonhub repo-create root/demo
git clone ssh://git@localhost:2222/root/demo.git
```

New repositories use `main` as their initial branch. Push an existing repository:

```sh
git remote add origin ssh://git@localhost:2222/root/demo.git
git push -u origin main
```

For an organization repository, first create the team in the web UI. For another
user's personal repository, first activate that user's account. The owner segment
must match the corresponding team's `name_key`.

Use `--visibility public` to allow every active moonhub user to read a repository.
Both SSH and the web UI still require authentication; public does not currently
mean anonymous access. Team `owner`, `admin`, and `member` roles may fetch and
push; site administrators may access all registered repositories.

To import an existing bare repository, place it at
`/data/repos/<owner>/<name>.git`, owned by UID/GID `10001:10001`, then register it:

```sh
docker compose exec --user git web mkdir -p /data/repos/root
docker compose cp /absolute/path/existing.git web:/data/repos/root/existing.git
docker compose exec --user root web chown -R git:git /data/repos/root/existing.git
docker compose exec --user git web moonhub repo-create root/existing --import
```

Import does not rewrite the Git history or default branch. It rejects non-bare
repositories and symbolic-link namespace aliases. Only import repositories from
trusted administrators: Git configuration and server-side hooks are executable
server configuration, not ordinary Git objects.

**Upgrade note:** disk directories alone no longer grant access. Existing
repositories must be explicitly registered and associated with a team before
they are available through either the web UI or SSH. Database schema migrations
run automatically in `web` before the server becomes healthy. SSH waits for that
initialization and never runs migrations from an authentication request.

## Network and Operations

Default published endpoints:

- HTTP: `127.0.0.1:8080`, intended for a local reverse proxy.
- SSH: `0.0.0.0:2222`, using the single system login name `git`.

Set Compose interpolation variables in your shell or in the project's `.env`:
`MOONHUB_HTTP_BIND`, `MOONHUB_HTTP_PORT`, `MOONHUB_SSH_BIND`,
`MOONHUB_SSH_PORT`, and `MOONHUB_ROOT_USER`. For example:

```sh
MOONHUB_HTTP_PORT=8090 MOONHUB_SSH_PORT=2223 docker compose up -d --wait
```

Use a TLS reverse proxy for public HTTP access and publish only the intended SSH
port through the host firewall. Replace `localhost` and the port in clone URLs
with your deployment's external hostname and SSH port. Port 22 also permits the
usual `git@host:owner/repository.git` form.

Verify the server fingerprint through the deployment's trusted console before
accepting it on a client:

```sh
docker compose exec ssh ssh-keygen -lf /var/lib/moonhub/ssh/ssh_host_ed25519_key.pub
docker compose ps
docker compose logs -f web ssh
```

OpenSSH permits public-key authentication only. User commands are restricted to
Git fetch and push, and shell access, PTYs, SFTP, forwarding, user startup scripts,
and arbitrary client environment variables are disabled. Git protocol v2 is
supported through `GIT_PROTOCOL`. Each push has a 1 GiB input limit and incoming
objects are checked by Git. Git LFS, upload-archive, deploy keys, branch protection,
and per-repository role overrides are not part of this version.

SMTP variables from the top-level `.env.example` are forwarded only to `web`;
the default transport writes invitation messages under `/data/mail_outbox`.

Rebuild and upgrade with `docker compose up -d --build --wait`. Take a backup before
upgrading: stop both services and back up both named volumes, including all SQLite
files. Preserve the SSH host-key volume on restore to avoid changing the server
identity. `docker compose down` retains the volumes; **`docker compose down -v`
deletes the repositories, database, and SSH host keys**.

## Verification

```sh
moon test
bash scripts/docker-smoke.sh
```

The smoke test builds the image and uses a uniquely named Compose project,
temporary bootstrap secret, dynamic loopback ports, and disposable volumes. It
checks activation, key binding, push/clone/fetch with binary data, forbidden
commands and forwarding, unknown keys, restart persistence, and revocation on
both new and existing SSH connections. Its cleanup removes only its own test
containers and volumes. Set `MOONHUB_SMOKE_SKIP_BUILD=1` to test an already built
`moonhub:local` image.
