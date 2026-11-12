# Repository Deploy Keys

Deploy keys authenticate deployment machines to one repository without borrowing
the creator's user permissions. Repository owners/admins (and site administrators)
manage them under **Repository > Deploy keys**. Only OpenSSH Ed25519 public keys
are accepted. Never paste or upload a private key.

## Access and Lifecycle

- New keys are read-only: clone, fetch and `ls-remote`. **Allow write access** is
  an explicit opt-in and can be changed later.
- A public key can be registered only once across all repositories and user SSH
  keys. Revoked keys remain reserved. Generate a different key for each repository
  and each rotation; changing comments does not create a new key.
- Access is checked for each SSH Git command, including new commands on an
  existing multiplexed connection. Changing the requested repository, even to a
  public repository, does not broaden access.
- Writable keys obey branch protection and may update only branches and tags.
  They cannot update MoonHub's internal refs, run Pipelines, or create executable
  push-trigger events. The creator's administration/runner rights are not inherited.
- Keys grant no login session, shell, port forwarding, PTY, or site administration.
- Creation, access changes and revocation are recorded in the repository audit.
  Settings show the fingerprint, creator, creation time, last operation start and
  revocation time. A last-used timestamp is not a successful-transfer receipt.
- Revocation rejects subsequent operations. In-progress transfers are not killed;
  receive hooks recheck authorization before accepting a push. Repository deletion
  revokes its keys and retains their fingerprints as tombstones. Recreating the
  repository path does not restore old access. Other repositories are unaffected.
- Keys belong to the repository, not the creator's account. Removing or disabling
  the creator does not silently rotate repository credentials; revoke them explicitly.

## Generate and Register

On the deployment server, as the account that owns the deployment clone:

```sh
install -d -m 700 ~/.ssh
ssh-keygen -t ed25519 -f ~/.ssh/moonhub_repository_deploy -C 'repository deployment'
chmod 600 ~/.ssh/moonhub_repository_deploy
cat ~/.ssh/moonhub_repository_deploy.pub
```

Choose a passphrase and an agent/secret-management policy appropriate to the
deployment. For unattended operation, a passphrase-less key must be protected by
filesystem permissions and host access controls. The private file stays on this
server. Register only the `.pub` contents on the repository's deploy-key page,
with a recognizable name and write access left unchecked.

Operators may alternatively register the public file through the trusted CLI
inside the Web container, running as `git` with the existing database:

```sh
moonhub deploy-key-add compiler/moonhub --actor root \
  --title moonhub-server-deploy --file /tmp/repository_deploy.pub
moonhub deploy-key-list compiler/moonhub --actor root
```

The actor must be an active repository manager. The CLI is an operator tool, not
an endpoint exposed to SSH clients; its actor option does not grant a deploy key
user privileges. `--write` explicitly opts into push access.

## Strict Host Verification

Obtain the server's Ed25519 host public key through a trusted administrative
channel, for example the existing administrator SSH connection:

```sh
docker compose exec -T ssh cat /var/lib/moonhub/ssh/ssh_host_ed25519_key.pub
```

Verify its fingerprint with the operator. Put that key in a dedicated known-hosts
file with `[git.example.com]:12222` as its first field. `ssh-keyscan` by itself
does not establish trust. Never disable host-key checking to make a pull work.
Use a dedicated SSH host alias, substituting the actual hostname and port:

```sshconfig
Host moonhub-repository-deploy
  HostName git.example.com
  Port 12222
  User git
  IdentityFile ~/.ssh/moonhub_repository_deploy
  IdentitiesOnly yes
  BatchMode yes
  StrictHostKeyChecking yes
  UserKnownHostsFile ~/.ssh/moonhub_deploy_known_hosts
```

```sh
git remote set-url origin moonhub-repository-deploy:compiler/moonhub.git
git pull --ff-only
```

Pinning a per-repository `core.sshCommand` with these options is also supported.
Do not use a broad user/admin SSH key as an automatic fallback.

## Rotation and Temporary Root-Key Migration

1. Upgrade Web and SSH together so both use the supported schema and trusted hooks.
   See [database compatibility](../db/README.md) for older databases.
   Back up the database and matching images with the deployment wrapper first.
2. Generate a **new** server key, register its public half read-only for the
   intended repository, and verify the fingerprint. Keep the working old key.
3. Test `git ls-remote` and `git pull --ff-only` with the new key and strict host
   checking. Ensure the SSH command selects only the new identity. Check the
   deploy key's last-used timestamp.
4. Persist the clone's SSH configuration. Only after the successful pull, revoke
   the old key and verify it no longer authenticates.
5. For the original `compiler/moonhub` deployment, the temporary key to revoke
   is the root-account key named `moonhub-server-deploy`. Inspect its ID and
   fingerprint with `moonhub ssh-key-list --user root`; then run
   `moonhub ssh-key-revoke ID`. Do not attempt to rebind that same public key.
6. For subsequent rotations, use repository settings or
   `moonhub deploy-key-revoke compiler/moonhub ID --actor root`.

If the replacement pull fails, leave the old key working and repair the host
verification or repository configuration before continuing. A rollback restores
the matching database and images together.

## Verification

```sh
moon test --strip -j 1
moon build --strip -j 1
node scripts/deploy-keys-smoke.cjs
MOONHUB_SMOKE_DOCKER=1 MOONHUB_IMAGE=moonhub:local node scripts/deploy-keys-smoke.cjs
bash scripts/docker-smoke.sh
```

The focused smoke requires Node 22.13+ (built-in SQLite), Playwright/Chromium and
Git/OpenSSH. Its default mode uses real Git upload/receive-pack and trusted hooks
with a local SSH connection adapter. Its Docker mode requires a current image
(build with `deploy/deploy.sh build`) and exercises real OpenSSH authentication,
strict host checking, forwarding denial and multiplexed revocation, using only
disposable containers/volumes. Both modes cover browser forms at desktop and
mobile widths and reject authorization cached while a receive hook waits for
input. The general Docker smoke retains user-key transport regression coverage.

## Deployment Acceptance Record

On 2026-09-28, `compiler/moonhub` was upgraded to implementation commit
`bf29034e932460d0a108c4f7c895be9cb5ea9e3a`, with matching Web/SSH, Provider and
Runner images and a pre-upgrade recovery backup. Repository deploy key ID 1
(`moonhub-server-repository-deploy`) was registered read-only. Its fingerprint is
`SHA256:7XiXGrszgcKwcJ97GpY1hke21N6mijRz5qfxOgsX6XM`.

The deployment clone now pins that identity and uses strict host verification.
`git pull --ff-only` succeeded before and after revoking root-account SSH key
ID 2 (`moonhub-server-deploy`); an explicit authentication attempt with the old
key was rejected. All 329 MoonBit tests, focused real-OpenSSH/browser acceptance
and the general Docker SSH/import/revocation regression passed.
