# Docker Deployment

The Compose deployment runs the same image in two services:

- `web`: MoonBit HTTP server, running as the unprivileged `git` user.
- `ssh`: OpenSSH, with a privileged listener and unprivileged Git sessions.

The `data` volume contains repositories, SQLite (including its WAL files), and
file-transport invitation emails. The separate `ssh-host-keys` volume contains
the SSH server identity. Neither volume is replaced by an image rebuild.

## Prepared Local Preview

The local preview uses `deploy/compose.preview.yaml`, project `moonhub-preview`,
and separate persistent volumes. It binds only to loopback: HTTP on port `18080`
and Git SSH on port `12222`. Its `preview` account password is stored in the
Git-ignored `deploy/secrets/preview_password` file.

Start or resume the prepared environment with:

```sh
docker compose --env-file /dev/null -f compose.yaml -f deploy/compose.preview.yaml up -d --wait
```

The prepared `Workshop` team contains `empty` and `example`. The latter was
imported from the sample source repository. To try another import in this team,
use `ssh://git@127.0.0.1:12222/preview/source.git` in the SSH import form. The
server maps this instance's public address to `ssh:2222` inside the Compose
network. Host clients can use the same public address after registering their
public key in the preview account. In **Site settings > SSH access**, the
prepared preview uses hostname `127.0.0.1` and port `12222`.

The overlay requires the provisioned preview password and credential directory
under `deploy/secrets`; these are deliberately not committed. It does not use
the production database or repository volumes.

## Start

Requirements: Docker Engine/Desktop with Docker Compose v2 or later. The optional
smoke test requires Compose 2.24.4 or later for its port overrides, plus Bash,
Python 3, curl, Git, and OpenSSH client tools on the host.

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
before a key can be registered.

Signed-in users can open **SSH keys** in the site header (or visit
`/-/settings/ssh-keys`) to add and revoke their own keys. The page shows each key's
SHA256 fingerprint, creation time, last use, and revocation status. Revoking a key
requires confirmation. These pages never expose another user's keys, including
when the signed-in user is a site administrator. Mutations require a session-bound
CSRF token.

Accounts change their own display name under **Profile** in the site header (or
`/-/settings/profile`). The username is read-only there because it names the
account's personal repository namespace.

Operators can still administer keys through the container CLI:

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

On a namespace page (`/<name>`), **New repository** creates an empty repository
and **Import via SSH** copies a remote repository. Team owners/admins and site
administrators may create repositories in a team; ordinary members may access
existing repositories but not create them there. Activating an account also
creates a personal namespace named after the username, and its owner creates
repositories there from **New repository** on the repositories page. Names are
reserved immediately, and a background worker prepares the
Git data before making it available through the browser or SSH. The status page
refreshes while work is queued or running. Failed operations can be retried or
discarded to release their reserved name.

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

## SSH Import

An import is a one-time mirror of Git refs and objects, including branches and
tags. It preserves Git's cloned default branch and does not keep synchronizing
with the source. The upstream remote is removed after cloning. Submodule
repositories and Git LFS object storage are not imported.

Incoming user keys and outbound import identities are separate. Configure one
read-only import identity per team, using the team's `name_key` as the directory
name. For a team named `acme`:

```sh
mkdir -p deploy/ssh-import/acme
ssh-keygen -t ed25519 -N '' -f deploy/ssh-import/acme/id_ed25519
printf '%s\n' 'git.example.com:22' > deploy/ssh-import/acme/allowed_hosts
ssh-keyscan -t ed25519 git.example.com > deploy/ssh-import/acme/known_hosts.candidate
ssh-keygen -lf deploy/ssh-import/acme/known_hosts.candidate
```

Verify the candidate host-key fingerprint against the source server's trusted
console or administrator before renaming `known_hosts.candidate` to `known_hosts`.
Do not trust a key solely because `ssh-keyscan` returned it. Add
`id_ed25519.pub` to the source repository as a **read-only deploy key**, then run:

```sh
mv deploy/ssh-import/acme/known_hosts.candidate deploy/ssh-import/acme/known_hosts
chmod 600 deploy/ssh-import/acme/id_ed25519 deploy/ssh-import/acme/known_hosts deploy/ssh-import/acme/allowed_hosts
docker compose up -d --build --wait
```

Enter a source such as `git@git.example.com:group/repo.git` or
`ssh://git@git.example.com:2222/group/repo.git` in the team's import form. DNS
hostnames, IPv4, and bracketed IPv6 URI addresses are supported. Usernames and repository path
segments must use ASCII letters, digits, dots, underscores, and hyphens (the SSH
username does not accept dots); spaces, URL passwords, shell expressions,
parent-directory segments, and other transport protocols are rejected.

`allowed_hosts` contains one exact, lowercase `hostname:port` per line, including
`:22` for the default port. Blank lines and `#` comments are ignored; wildcard
hosts are not supported. A non-default port also requires a corresponding
`[hostname]:port` entry in `known_hosts`. This allowlist controls outbound network
access, including access to any internal Git servers you explicitly allow.
IPv6 allowlist entries use `[address]:port`.

When a source's normalized host and port exactly match this instance's configured
public or internal SSH endpoint, Moonhub treats it as a local repository import.
The requester must be able to read the source and manage the destination team.
The queued job records the source repository ID, then connects using
`MOONHUB_SSH_INTERNAL_URL`. The destination team's credentials, `allowed_hosts`,
and `known_hosts` must authorize that **internal** host and port, such as
`ssh:2222` and `[ssh]:2222`. This does not bypass SSH authentication or host-key
verification. Source permission is checked again before cloning and publishing.
Deleting a source fails the job even if another repository later reuses its name.
Changing the public address does not redirect already queued local or external
jobs. Legacy jobs are classified when first resumed. Other source endpoints are
used unchanged; configure the canonical address rather than unconfigured aliases.

Compose mounts `${MOONHUB_SSH_IMPORT_DIR:-./deploy/ssh-import}` read-only. At web
startup, the three files are copied into a private runtime directory owned by the
unprivileged service user. Symlink credentials are rejected. Private import keys
are never uploaded through the web UI, stored in Git, or included in the Docker
build context. Keep custom credential directories outside the checkout. Back up
this directory separately and protect it as a secret.
After changing credentials or host pins, run `docker compose restart web` and
retry a failed operation. User login keys are never used implicitly for imports.

Imports use strict host-key verification, no SSH agent or forwarding, and only
the selected team's identity. One repository operation runs at a time per shared
repository root. The timeout defaults to 300 seconds; set
`MOONHUB_IMPORT_TIMEOUT_SECONDS` to a value from 1 to 3600 if needed. Use volume
quotas when untrusted team administrators can import large repositories. Git
diagnostics are bounded, and failed attempts are cleaned out of staging. A shared
filesystem lock and publication marker let interrupted jobs recover after a
restart without exposing partially cloned repositories or replacing existing
repository data.

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

### Public SSH Address

Site administrators can open **Site settings** from the **Administration**
group in the sidebar, or from the account menu (`/-/admin/settings/ssh`),
and save the hostname/IP and port that clients can reach. The SSH username is
fixed to `git`. Repository pages expose this address in a **Clone** menu with a
copy button. Without a configured public address, the menu reports that it is
not configured; it never guesses from HTTP headers or exposes a container name.

The effective endpoint uses `MOONHUB_SSH_PUBLIC_URL` when nonempty, otherwise the
database setting. An environment override must be a complete endpoint such as
`ssh://git@git.example.com:2222` (no repository path). It makes the admin form
read-only; removing it restores the saved database setting. Database edits apply
on the next request. Environment changes require recreating the web container.

The deployment-only `MOONHUB_SSH_INTERNAL_URL` defaults in Compose to
`ssh://git@ssh:2222`. It is shown read-only to administrators and is used only
for same-instance imports. It is separate from the public address and from
`MOONHUB_SSH_BIND` / `MOONHUB_SSH_PORT`, which control Docker port publishing.
Editing the website setting does not change listeners, DNS, firewall rules, or
Docker port mappings. For host-side preview use `127.0.0.1:12222`; remote clients
need a reachable domain/IP instead of loopback.

Use a TLS reverse proxy for public HTTP access and publish only the intended SSH
port through the host firewall. Port 22 also permits the usual
`git@host:owner/repository.git` form.

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
objects are checked by Git. Git LFS, upload-archive, deploy keys, and
per-repository role overrides are not part of this version.

Repository pages include **Issues** and **Merge Requests**. Team administrators
configure exact-name branch protection from the MR list. Protection is enforced
by the deployment-owned SSH receive hook, including for administrator pushes.
Use the same image version for web and SSH when upgrading. See
[collaboration behavior and architecture](../docs/collaboration.md) for review,
merge recovery, limits and permissions.

SMTP variables from the top-level `.env.example` are forwarded only to `web`;
the default transport writes invitation messages under `/data/mail_outbox`.

Rebuild and upgrade with `docker compose up -d --build --wait`. Take a backup before
upgrading: stop both services and back up both named volumes, including all SQLite
files. Preserve the SSH host-key volume on restore to avoid changing the server
identity. `docker compose down` retains the volumes; **`docker compose down -v`
deletes the repositories, database, and SSH host keys**.

## Verification

```sh
moon test --strip -j 1
bash scripts/docker-smoke.sh
```

Native tests use the temporary [compiler workaround](../README.md#temporary-compiler-workaround),
including during Docker image builds. Production release builds are unchanged.

The smoke test builds the image and uses a uniquely named Compose project,
temporary bootstrap secret, dynamic loopback ports, and disposable volumes. It
checks activation, self-service web key binding, team repository creation,
SSH import with a rejected host key followed by a successful retry, branch/tag
preservation, push/clone/fetch with binary data, forbidden commands and forwarding,
unknown keys, restart persistence, and revocation on
both new and existing SSH connections after web revocation. Its cleanup removes only its own test
containers and volumes. Set `MOONHUB_SMOKE_SKIP_BUILD=1` to test an already built
`moonhub:local` image.
