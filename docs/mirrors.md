# Push mirrors

Repository owners and administrators configure **Mirrors** in repository settings.
A push mirror copies all `refs/heads/*` and `refs/tags/*` to an SSH destination,
for example `git@github.com:organization/repository.git`. A repository can have
up to five destinations. Enabling or editing a mirror queues an initial full
sync; subsequent managed SSH pushes (including write deploy keys) and MR merges
queue another sync. CI and Webhooks do not need to be enabled.

MoonHub is the source of truth. This is one-way push mirroring; external changes
are not imported. Private merge, pipeline and other internal refs are excluded.
Annotated tag objects are preserved. Git LFS objects and submodule repositories
are not transferred. Changes made directly to repository files outside MoonHub
are not automatic triggers; **Sync now** reconciles the current refs.

## Credentials and destination policy

Each mirror has its own generated Ed25519 key pair, stored in the database.
Create a mirror, copy the public key from **SSH authentication**, and add it to
the destination repository as a **write-enabled deploy key**. Then enable
automatic sync. New mirrors start disabled so the destination can be authorized
before the first transfer. The browser only displays the public key.

**Rotate SSH key** replaces that mirror's key pair and disables automatic sync.
Authorize the new public key, remove the old deploy key at the destination, then
enable sync again. Other mirrors keep their keys. Deleting a mirror removes its
key pair from the database. Existing mirrors are paused on upgrade; save each
mirror to generate its independent key, authorize it, and enable it again.

Private keys are stored as plaintext because the worker needs to authenticate
unattended. Protect the database and its backups as credentials. The worker
materializes a mode `0600` key file in a private temporary directory only for the
transfer and removes it afterward. Key generation also uses private temporary
files, which are removed after the key pair is saved.

After saving a disabled mirror, choose **Initialize destination**. MoonHub fetches
its Ed25519 host public key and displays the SHA256 fingerprint for the saved
SSH destination. Compare it with the host's published fingerprint or verify it
with the server administrator, then choose **Trust this host key**. Fetching a
key alone does not establish its authenticity. Add the mirror's public key as a
write-enabled deploy key at the destination, then enable automatic sync.

The pending scan and confirmed host trust are stored in the database, scoped to
this mirror and destination host/port. Confirmation uses a one-time challenge,
expires after ten minutes, and is invalidated by another scan or configuration
change. The submitted form cannot replace the scanned key. Another mirror does
not inherit trust. No site-administrator approval, SSH import configuration,
namespace credentials or manually created directory is needed.

Changing the destination host or port clears its trust and requires initialization
again. To replace a changed host key, disable sync, save, fetch the fingerprint
again and explicitly confirm the replacement after checking with the server
administrator. A changed fingerprint is highlighted. Merely fetching a new key
never replaces a trusted key or enables sync. Saving and rotating a disabled
mirror do not require network access or trusted host keys. Existing mirrors
preserve their identities and history on upgrade; initialize their destinations
before enabling them. An enabled legacy mirror without pins fails closed.

SSH runs without an agent and verifies the destination strictly against a mode
`0600` temporary known_hosts file generated from that mirror's database pins.
The host key and identity files are removed with the private transfer directory.
Unknown or changed server host keys cause sync to fail. The worker rechecks the
configuring user's active account and management permission before external I/O.
Revoked access stops queued work; another manager can save the mirror to take
ownership. HTTPS/token URLs and arbitrary Git transports are rejected.

The mirror transport defaults to `/usr/bin/ssh` with isolated settings and
strict host checking; it does not use the SSH import wrapper. Deployments may
set `MOONHUB_MIRROR_SSH_COMMAND` to a trusted command that honors
`MOONHUB_MIRROR_IDENTITY` and `MOONHUB_MIRROR_KNOWN_HOSTS`. This is
an operator-only override, not a repository form field. Host initialization uses
`/usr/bin/ssh-keyscan` (or the operator-only `MOONHUB_MIRROR_KEYSCAN` override),
with a five-second connection timeout, ten-second overall timeout and bounded
output. It does not authenticate with or expose the mirror identity.

## Force updates and deletion

Both options default to off and apply to branches **and** tags:

- **Allow force updates** replaces diverged branches and moved tags. Without it,
  Git rejects conflicting updates and the attempt is recorded as failed.
- **Delete remote branches and tags** prunes destination refs absent from MoonHub,
  including destination-only refs during the first sync. Keep it off to preserve
  branches and tags maintained only on the destination.

Remote branch protection still applies. Git may accept some refs before rejecting
others; retries reconcile the latest complete source snapshot. Do not use the
mirror destination for independent writes when force updates or deletion are on.
Disabling or removing the mirror leaves the destination repository intact.

## Delivery and recovery

Updates are durable and coalesced: several pushes may be represented by one sync
of the latest refs rather than one external push per commit. A successful attempt
records its generation; an update arriving during a transfer remains queued.

Each transfer snapshots branches, tags and reachable objects under the source
repository write lock, then releases it before external network I/O. Incoming
pushes and MR merges never wait on the destination network. Per-mirror locks
serialize transfers, edits, key rotation, deletion and manual retry across server processes.
An edit attempted during a long transfer may report that the mirror is busy;
retry after the transfer finishes. Failed transfers never roll back accepted
source pushes or merges.

Failures retry after 10 seconds, 1 minute, 5 minutes and 30 minutes, stopping after
five attempts. **Sync now** starts another retry cycle. A subsequent source update
also starts a new cycle. The page shows status, last successful sync and the ten
most recent attempts; the database retains the most recent fifty attempts.
Diagnostics contain application-authored recovery guidance, never Git/SSH output
or credential paths. The transfer timeout uses `MOONHUB_MIRROR_TIMEOUT_SECONDS`.

Prepared reference transactions are recovered under the source write lock after
a process interruption, including branch and tag deletion. Aborted pushes are
ignored. An ambiguous ref requires operator inspection. A worker lost mid-transfer
is retried after its two-hour lease expires; a filesystem lock prevents a live
worker from being duplicated. Temporary snapshots are removed on ordinary exit;
a process killed without cleanup can leave private directories under `.mirrors/`.
Operators may remove abandoned snapshot directories when no mirror worker is active.
