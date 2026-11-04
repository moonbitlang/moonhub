# Docker Deployment

For the current production deployment on `moonhub-web`, use
[Git checkout + SSM + standalone ASG](production.md) and `deploy/production.sh`.
The DinD/shared-host profiles below remain available for existing deployments.

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
./deploy/deploy.sh build-base
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

The base installs dependencies with `npm ci`; the application image builds browser
assets and compiles the native executable on Linux, without running tests. No
host MoonBit or Node installation is needed. Set `MOONBIT_VERSION` for `deploy.sh`
to select an archived MoonBit toolchain release;
its default is `0.10.19+8e43a47fb-nightly`, matching the formatter syntax in this
repository. Upgrade the dependency base and Runner together with the application;
older toolchains cannot parse the new `#derive(...)` attributes or inclusive
range patterns. Dependency resolution checks the downloaded packages without
modifying their manifests or tracked application inputs.

### Dependency Base Image

`deploy.sh` builds one local dependency base image before application images.
The base contains the Debian packages, MoonBit toolchain, Mooncakes dependencies,
and npm dependencies needed by the build. Its tag is derived from the target
platform, dependency manifests, toolchain version and mirror mode. A normal
source-code upgrade therefore reuses the existing base and does not repeat the
long network steps. The application build runs its compile and frontend build
with networking disabled. Dependencies and toolchain binaries remain in this
single shared base for all roles, so runtime images are intentionally larger.
`runner-selfhost` is kept as a compatible target name; both runner targets now
include Node/npm.

The base is local to the production Docker daemon; it is not a registry and does
not need to be published. `upgrade` and `build` create it automatically only if
the derived tag is missing:

```sh
./deploy/deploy.sh build-base
./deploy/deploy.sh build
```

Use `MOONHUB_BASE_REBUILD=1 ./deploy/deploy.sh build-base` to force a refresh,
for example to pick up newer Debian security packages or a refreshed Mooncakes
index. A cached base does not acquire security updates automatically: refresh it
on the operator's regular patch schedule, then run `upgrade`.
`MOONHUB_BASE_IMAGE` can select an operator-built **local** image instead; it is
checked, never downloaded or rebuilt. Do not combine it with `MOONHUB_BASE_REBUILD`.
An explicit base must match this checkout's dependencies and target architecture;
its source configuration is already baked in, so the CN switch cannot change it.

`MOONHUB_PULL=1` applies to the base's parent only when creating or forcing the
base, and still applies to the DinD/pre-published Runner images. Application
builds never use `--pull` for the locally generated base. Use Docker's local
daemon builder; a remote builder with a separate image store cannot see these
local images. No registry is introduced by this workflow.

`build-base` also creates the convenience tag `moonhub-base:local` for direct
Docker/Compose builds. Run it first (with the desired mirror settings) before
manual `docker build` or `docker compose ... --build`; `deploy.sh build/upgrade`
select the dependency-specific tag themselves. `MOONHUB_BUILD_IMAGES=0` continues
to use only the prebuilt application images and does not require the base image.

### Build Download Sources

`deploy.sh` uses official sources by default. Set `MOONHUB_USE_CN_MIRRORS=1`
to switch both Debian packages and MoonBit toolchain downloads to domestic
endpoints with one environment variable:

```sh
env MOONHUB_USE_CN_MIRRORS=1 MOONHUB_ENABLE_PIPELINES=1 ./deploy/deploy.sh upgrade
```

| Setting | Debian packages and security updates | MoonBit installation | Mooncakes index/packages |
| --- | --- | --- | --- |
| Unset or `0` | `deb.debian.org` | `cli.moonbitlang.com` | Official defaults |
| `1` | `mirrors.ustc.edu.cn` | `cli.moonbitlang.cn` | USTC mirror |

For persistent settings, add `MOONHUB_USE_CN_MIRRORS=1` to `deploy/deploy.env`
(or the file selected by `MOONHUB_DEPLOY_ENV_FILE`). As with other deployment
settings, the settings file overrides the inherited shell environment. Only
`0` and `1` are accepted; invalid values fail before any service is stopped.
`deploy.sh` includes the switch in the base image identity used by all roles;
operators do not need to pass Docker build arguments themselves.

The `.cn` installer is the official installer linked from the MoonBit Chinese
download page. It downloads both the version-pinned toolchain and core from
`cli.moonbitlang.cn`, rather than fetching only the script there and downloading
archives from `.com`. Failed script downloads are not executed. The installer
also writes the image's Mooncakes `config.json`: domestic mode uses
`https://mirrors.ustc.edu.cn/mooncakes.git` for the index and
`https://mirrors.ustc.edu.cn/mooncakes` for downloads, with the API remaining
`https://mooncakes.io`. Runner jobs inherit this configuration into their private
Moon homes. Do not set `MOONCAKES_REGISTRY` to the mirror: its inferred index URL
would be incorrect. The switch does not change Docker Hub or npm, and no public
mirror guarantees every network path.

HTTP is used to bootstrap `ca-certificates` in the slim base image. Package
authenticity remains verified against Debian's bundled archive signing keys;
signature checks and Release expiry checks are not disabled. Mirrored security
updates can lag upstream. APT uses a 30-second connection/data timeout and at
most two retries per download; any failed index fetch fails the build. These
limits are not a total build timeout.

With domestic sources enabled, `DEBIAN_MIRROR` and `DEBIAN_SECURITY_MIRROR`
can override the two APT URLs in `deploy/deploy.env`. Their defaults are:

```sh
DEBIAN_MIRROR=http://mirrors.ustc.edu.cn/debian
DEBIAN_SECURITY_MIRROR=http://mirrors.ustc.edu.cn/debian-security
```

`MOONHUB_USE_CN_MIRRORS=0` ignores these overrides and uses the official sources.
HTTPS mirrors
require CA certificates to already be available in the base image; do not disable
certificate verification to work around bootstrap failures. Failed builds leave
the running deployment untouched. Verify the configuration with
`node scripts/apt-config-test.cjs`, `node scripts/moonbit-install-test.cjs`,
`node scripts/base-image-test.cjs` and `node scripts/deploy-script-test.cjs`.

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

Push mirrors have independent database-backed credentials and destination trust.
Repository managers initialize the destination and confirm its displayed SSH
host fingerprint in the mirror settings;
no import directory or credential files are needed. Authorize each mirror's
public key as a write-enabled deploy key at the destination. See
[push mirrors](../docs/mirrors.md).

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
startup, the policy files and optional import key are copied into a private
runtime directory owned by the unprivileged service user. Symlink credentials are rejected. Private import keys
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

For manual Compose builds, refresh/check the dependency base with
`./deploy/deploy.sh build-base` before `docker compose up -d --build --wait`.
Prefer the deployment wrapper below for production. Take a backup before
upgrading: stop both services and back up both named volumes, including all SQLite
files. Preserve the SSH host-key volume on restore to avoid changing the server
identity. `docker compose down` retains the volumes; **`docker compose down -v`
deletes the repositories, database, and SSH host keys**.

For production, use the tracked deployment wrapper after pulling a clean Git
revision. It builds all images while services remain up, then stops the target
services, creates a consistent volume backup, and starts the new release:

```sh
./deploy/deploy.sh upgrade
```

Pipeline services are included when `MOONHUB_ENABLE_PIPELINES=1`. The wrapper
builds the Runner image locally and loads it into the new persistent DinD
daemon, so no registry is required for this deployment mode:

```sh
MOONHUB_ENABLE_PIPELINES=1 ./deploy/deploy.sh upgrade
```

For repeat deployments, put operator settings such as
`MOONHUB_ENABLE_PIPELINES=1`, `MOONHUB_BACKUP_DIR`, and secret paths in an
operator-owned file and set `MOONHUB_DEPLOY_ENV_FILE` to that path. Use
`./deploy/deploy.sh build` to build without downtime, `backup` to create a
backup only, `status` to inspect services, and `config` to validate the
resolved Compose configuration. For a provider shared by all current and future
repositories, persist these settings in `deploy/deploy.env`:

```sh
MOONHUB_ENABLE_PIPELINES=1
MOONHUB_PROVIDER_SCOPE=all
MOONHUB_PROVIDER_REPOSITORIES=
```

Use `MOONHUB_PROVIDER_SCOPE=selected` with a comma-separated
`MOONHUB_PROVIDER_REPOSITORIES` list for restricted access. If scope is unset,
new providers default to selected and existing providers keep their saved scope,
including changes made through Administration. Manage existing grants through **Edit access**; deployment does not re-add removed
grants. Direct CLI ensure without `--preserve-existing` retains its explicit
configuration behavior. Provider labels, scope and repository lists in the deployment file are bootstrap
defaults used only when registering a new provider. Upgrades use
`pipeline-provider-ensure --preserve-existing` and preserve existing labels,
repository scope/grants, pause state and credentials from the database. Web
administration is authoritative for existing providers; stale deploy-file settings
never reset it. Credential mismatches and revoked providers still fail closed.
All-repository scope with a nonempty repository list is rejected before building
or stopping services. Labels and requester authorization still apply in both
scopes.

The wrapper idempotently registers the provider after Web
is healthy and before starting the provider service. The wrapper refuses a
dirty Git worktree and never stops services before a successful build.

The default settings file is `deploy/deploy.env` (Git-ignored); once configured,
subsequent updates need only `git pull` followed by `./deploy/deploy.sh upgrade`.
Use this file to persist ports, project name, secret paths and the pipeline
toggle, so manual Compose commands cannot accidentally select another image.
Set `MOONHUB_BUILD_IMAGES=0` only with prebuilt Web/provider/Runner images; all
must be present locally before the script stops services. `MOONHUB_PULL=0`
skips forced base-image refresh but does not guarantee an offline Docker build.
Registry-free deployments load the local Runner image into the private DinD
daemon through its Unix socket. Runner images must match the production CPU
architecture.

The first installation still requires root activation. Selected repositories
listed in `MOONHUB_PROVIDER_REPOSITORIES` must exist before provider ensure
can succeed; all-repository scope does not require pre-creating repositories.
Start with pipelines disabled for root bootstrap; do not relax
the active-administrator or repository-grant checks. Upgrades preserve paused
provider state. Drain active jobs before upgrading.

After upgrading Web and SSH together, automatic push workflows can be enabled
per repository on its Pipelines page with **Run push workflows**. The setting
defaults off. The image installs executable `pre-receive` and
`reference-transaction` hooks; custom/non-Docker SSH deployments must install
both from `deploy/hooks` in the trusted hook directory. The automatic trigger
worker runs in Web and resumes persisted events after restart. See
`docs/pipelines.md` for supported push filters and the owner/admin-only policy.

Recovery preserves saved provider scope in the database. The generated
`upgrade.env` also preserves an explicitly configured scope for subsequent
upgrades; older backups without this setting leave scope unchanged.

The deployment wrapper additionally requires `jq` and `sha256sum` (or `shasum`).
The `backup` command requires Web/SSH/provider to be stopped, but DinD must remain
running so its deployed Runner image can be exported. Drain pipeline jobs first.
Upgrades export existing images and configuration before stopping services; only
the consistent data copy takes place during downtime. Backups include SQLite/WAL,
repositories and SSH host keys in ownership-preserving tar streams, actual image
IDs and image archives, container configuration, bootstrap/provider secrets and
SSH import credentials. `manifest.json` distinguishes the recovery-tool revision
from the deployed image identities in `images.json`; it never presents the new
checkout as the old application version. `SHA256SUMS` covers bundle files.
Image archives are streamed through fast gzip compression. Their existing
`images.tar` and `runner.tar` names are retained; Docker load and Runner archive
validation accept compressed and older uncompressed files. Each bundle remains
self-contained, with checksums covering its exact stored bytes.

The private `.image-cache` under the backup root stores one compressed archive
per immutable image set/Runner ID. Repeated backups verify the cached checksum and
hard-link those bytes into the bundle, avoiding another export or duplicate disk
blocks. Copy a complete bundle normally for off-host recovery; neither the cache
nor another bundle is needed to restore it. Treat linked archives as immutable:
editing one in place also changes its other hard links. Corrupted cache entries
are replaced, and bundle checksums still reject corruption before restore.

`MOONHUB_BACKUP_KEEP` defaults to **2** complete bundles for the same Compose
project (`0` disables automatic retention; maximum 1000). Pruning runs only after
a successful upgrade/service switch or standalone backup. It retains the newly
created bundle even when timestamps collide, skips other projects and incomplete
directories, and removes cached archives after their last retained bundle is
deleted. Retention verifies the file inventory and checksums before counting a
bundle toward this limit. Damaged copies are reported and left for operator
inspection; they never displace a verified recovery point. This integrity check
reads the archives but does not export or duplicate them.
Failed builds/backups/startups never prune previous complete backups.
The deploy wrapper removes its own incomplete `.partial-` bundle on failure;
interrupted/killed processes may still leave partial artifacts for manual cleanup.

Protect the entire backup as a secret and retain an off-host copy. Image export
can still need Docker temporary disk space before compression; compression and
retention do not replace capacity monitoring.
External reverse-proxy/TLS configuration is outside this Compose backup's scope.
The wrapper does
not provide a distributed atomic switch or automatic database rollback: a
failure after stop returns nonzero and requires operator attention. After a
migration, restore the matching backup before rolling back the application.
Verify the deploy sequencing tests with `node scripts/deploy-script-test.cjs`.

## Restore And Rollback

### Shared Hosts

`MOONHUB_SHARED_HOST=1` selects `compose.shared-host.yaml`. This opt-in profile
uses a dedicated systemd cgroup v2
slice (`MOONHUB_CGROUP_PARENT=moonhub.slice`) and bounded DinD storage
(`MOONHUB_DIND_STORAGE_DIR=/srv/moonhub/dind/docker`). The tracked
`moonhub.slice` caps all attached workloads
at 4 CPUs, 10 GiB RAM, no swap and 1024 tasks. Services also have individual
limits and rotated logs; the provider is a single instance. Verify the actual
nested job cgroup before allowing work, not just the Compose configuration.

Set `MOONHUB_BUILD_IMAGES=1` and remove explicit `MOONHUB_IMAGE`,
`MOONHUB_PROVIDER_IMAGE`, `MOONHUB_RUNNER_IMAGE`, `MOONHUB_RELEASE_TAG` and
`MOONHUB_BASE_IMAGE` overrides to build the checked-out commit. A dedicated
BuildKit container is hard-limited to 2 CPUs, 4 GiB RAM (no swap), 512 tasks and
the same resource slice. The worker executes one build step at a time. It has
its own labeled cache volume, no published API port, no host Docker socket,
no application volumes and no deployment credentials. It is privileged to
support nested build workers and therefore remains part of the trusted host
control plane, not an untrusted job sandbox. Pipeline jobs continue while images
build; both workloads share the aggregate 4 CPU/10 GiB budget. The builder stops
on success/failure; its cache remains for subsequent upgrades. Cache GC targets
4 GiB, not a hard disk quota. Keep at least 12 GiB free for build/backup headroom. An operator can explicitly
override the build preflight with `MOONHUB_BUILD_MIN_FREE_GIB` (default `12`);
`0` disables only this capacity preflight. Build resource limits, committed
snapshots and backup-before-switch requirements still apply.

Bake links the dependency-base target directly into Web/provider/Runner builds;
no registry or local-base image export/import is required. Build inputs come
from `git archive HEAD`, excluding operator files. All output images are tagged
with the commit and checked against `org.opencontainers.image.revision` before
switching. `MOONHUB_BUILDKIT_IMAGE` can pin the trusted builder image by digest;
the default is `moby/buildkit:buildx-stable-1`. Shared-host `build-base` remains
disabled because the linked dependency base is managed by the application build.
`MOONHUB_BUILD_IMAGES=0` still supports explicitly pinned prebuilt images.

After configuring server Git authentication and the self-hosted repository as
`origin`, normal updates are:

```sh
git pull --ff-only
./deploy/deploy.sh upgrade
```

Only after successful builds does upgrade briefly freeze provider claims and
check both allocated attempts and job containers. Jobs themselves continue in
DinD during the confirmation. Active jobs require a `y`/`yes` response; Enter,
EOF or noninteractive execution refuse interruption and resume the provider.
For unattended deployments, `upgrade --interrupt-jobs` explicitly authorizes
interruption. Accepted interruption stops jobs with a 15-second grace period;
unconfirmed completions may become `lost`, and snapshot reruns remain explicit.
Backups and the Web/SSH switch happen afterwards. A backup failure restarts the
old provider without stopping Web/SSH; a failure after switching requires
operator recovery. No deployment path modifies other Compose projects.

Existing shared-host installations with an 8 GiB slice must deliberately update
their `moonhub.slice` to 10 GiB before enabling concurrent builds. Keep a GitHub
or bundle recovery source because pulling from MoonHub requires its Git service
to be available. Do not change the site's SSH host identity or disable host-key
checking merely to make the deployment clone authenticate.

On a compatible host, `sudo bash deploy/setup-shared-host.sh` provisions only
MoonHub's own units and a preallocated 12 GiB ext4 loop filesystem. It requires
34 GiB free before allocation and never formats an existing unexpected file.
The inner Docker store and workspaces share this 12 GiB total, including images;
it is not a 20 GiB per-job quota. The `docker` subdirectory exists only inside the
mounted filesystem so a missing mount fails closed. This avoids changing the
shared Docker daemon's data-root or restarting other services. Root filesystem
capacity for outer images, backups and application data still needs monitoring.

Backups preserve resource-limit metadata. Generic automated restore refuses
shared-host snapshots because a fresh bounded storage area and resource slice
must be provisioned before restoring them; do not restore them with an older
recovery script that silently discards limits.

`deploy/identity-transfer.py export SOURCE DESTINATION` exports only users,
teams, membership, invitation and user SSH public-key records from a read-only SQLite snapshot.
`import ... --schema-root db --schema-version 11|12|13` creates a fresh database
with those identities; it refuses existing destinations. Password hashes are
preserved, including public-key revocation state, but server SSH host keys,
sessions, password resets, mail settings/outbox,
repositories and pipelines are excluded. Export files are sensitive and mode
0600; transfer them over SSH without displaying contents. Existing users log
in with their old passwords and use their existing SSH keys. Verify
the helper with `python3 scripts/identity-transfer-test.py`.
When Python is absent from the old Web image, `export-identities.cjs` performs
the same export using Node 24's SQLite API and the shared `identity-tables.json`
allowlist. It reads a transaction snapshot and outputs counts only.

### Standard Restores

Backups made by the recovery-enabled wrapper are self-contained: no source
checkout, MoonBit, Node, registry or live MoonHub is needed to restore. The host
needs Bash, Docker/Compose, `jq` and `sha256sum`/`shasum`, on the same CPU
architecture as the saved images. Use only trusted backups: checksums detect
accidental corruption, not tampering by someone who can rewrite the bundle.
Keep enough free host and Docker disk space for image archives and a second copy
of the data. Protect backups and recovery state with private permissions, and
copy completed bundles off-host. A backup on the failed disk is not recovery.

From a checkout, restore with:

```sh
./deploy/deploy.sh restore /srv/backups/20260921-010000.ABCDEF
```

Or, when MoonHub and the checkout are unavailable, use the bundled entry point:

```sh
bash /srv/backups/20260921-010000.ABCDEF/recovery.sh restore /srv/backups/20260921-010000.ABCDEF
```

The original Compose project and ports are used by default. If it already has
containers, the command refuses to proceed unless `--replace` is supplied.
Replacement first exports the target's exact images/configuration, drains/stops
its provider, stops writers, and creates a protection backup. Data is restored
into **new volumes** before switching containers; old volumes are never deleted.
This command is also the rollback command: restore both the old data and its
matching image IDs, not just an old executable against a migrated database.
Do not use the same mutable image tag as a rollback identifier.
Image archives carry content-derived `moonhub-recovery` transport tags so Docker
classic and containerd stores can resolve their different ID representations;
the restored Compose file is pinned to the loaded local IDs, not those tags.

For an isolated rehearsal, specify another project and unused ports/subnet:

```sh
./deploy/deploy.sh restore /srv/backups/20260921-010000.ABCDEF \
  --project moonhub-rehearsal --http-port 18085 --ssh-port 12227 \
  --pipeline-prefix 172.30.95
```

Explicit port overrides bind to loopback. `--pipeline-prefix` is required for a
different project only when the backup includes pipelines. Choose a subnet that
does not overlap another Docker network. Restored settings in SQLite, including
public URLs, email delivery and SSH display addresses, are preserved: isolate
egress during a rehearsal and adjust those settings before treating the copy as
a different public instance. Never expose two writable copies as the same site.

Completed restore prints a durable recovery directory containing `compose.json`,
copied credentials, and `upgrade.env`. Keep this directory outside `_build` and
do not delete it while its services use the bind-mounted files. Use the printed
Compose command for start/stop/status of the restored release. For subsequent
normal upgrades, use the printed `MOONHUB_DEPLOY_ENV_FILE=.../upgrade.env` with
`deploy.sh upgrade`: it contains the **new volume names**, port/network settings
and secret paths. Review provider labels/repository grants and build policy before
upgrading. Do not reuse an old settings file pointing at the pre-restore volumes.
`MOONHUB_RECOVERY_STATE_DIR` overrides the default sibling `recovered/` directory.

Recovery does not restore in-flight job containers, workspace volumes, Docker
build caches or DinD storage. Drain jobs first; their durable records/logs remain
in SQLite and runner images are reloaded into a new DinD volume. Provider tokens,
IDs, grants and paused state are restored without provider re-registration.
The wrapper supports the tracked Web/SSH and optional provider/DinD topology;
unknown services or mounts are rejected instead of silently omitted. Old
directory-only backups lack images/configuration and require manual recovery.

Restore errors are fail-closed, not automatic rollback. Extraction/preflight
errors leave the running target alone; errors after the switch require operator
attention. The printed protection backup and original volumes remain available.
After verifying the restored instance and an off-host backup, operators can
explicitly remove obsolete volumes; never run an indiscriminate volume prune.

## Webhook destinations

Web sends signed repository Webhooks over HTTPS to public IPv4 receivers.
For trusted internal endpoints, configure comma-separated exact origins in
MOONHUB_WEBHOOK_ALLOWED_ORIGINS and restart Web. See
[Webhook policy and upgrade requirements](../docs/webhooks.md).

## Verification

For deployment clones, use [repository-scoped deploy keys](../docs/deploy-keys.md)
instead of a root/user SSH key. The guide covers server-side generation, strict
host verification, read-only registration, rotation and the temporary root-key
migration. Web and SSH must be upgraded together for schema 13.

```sh
moon test --strip -j 1
bash scripts/docker-smoke.sh
node scripts/deploy-script-test.cjs
node scripts/recovery-e2e.cjs
```

Tests run separately from Docker image builds, through the commands above or the
MoonHub self-check workflow. Run them before deploying a revision; a successful
image build is not a test result. Native tests use the temporary
[compiler workaround](../README.md#temporary-compiler-workaround).
Production image builds retain `moon build --target native --release --deny-warn`
and the C launcher's compiler warnings as errors.

The smoke test builds the image and uses a uniquely named Compose project,
temporary bootstrap secret, dynamic loopback ports, and disposable volumes. It
checks activation, self-service web key binding, team repository creation,
SSH import with a rejected host key followed by a successful retry, branch/tag
preservation, push/clone/fetch with binary data, forbidden commands and forwarding,
unknown keys, restart persistence, and revocation on
both new and existing SSH connections after web revocation. Its cleanup removes only its own test
containers and volumes. Set `MOONHUB_SMOKE_SKIP_BUILD=1` to test an already built
`moonhub:local` image.

The recovery drill uses existing `moonhub:acceptance`,
`moonhub-provider:acceptance` and `moonhub-runner:acceptance` images (override with
`MOONHUB_IMAGE`, `MOONHUB_PROVIDER_IMAGE`, `MOONHUB_RUNNER_IMAGE`). It uses ports
18084/12226 for its source and 18085/12227 for the restored instance, and subnets
172.30.94.0/24 and 172.30.95.0/24. `MOONHUB_RECOVERY_SOURCE_PORT`,
`MOONHUB_RECOVERY_SOURCE_SSH`, `MOONHUB_RECOVERY_TARGET_PORT`,
`MOONHUB_RECOVERY_TARGET_SSH`, `MOONHUB_RECOVERY_SOURCE_PREFIX` and
`MOONHUB_RECOVERY_TARGET_PREFIX` override them. It validates login, repository
files/commits, MR and pipeline records, a strict-host-key SSH clone, a new DinD
job, corruption rejection, replacement rollback and subsequent upgrade volume
names. It retains the restored project and private receipt/credentials under
`backups/moonhub-recovery-*` for inspection; source containers remain stopped.
No existing preview is modified.
