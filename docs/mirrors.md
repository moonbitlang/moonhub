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

Destination trust remains an administrator policy, shared with SSH imports:
`MOONHUB_SSH_IMPORT_ROOT/<namespace>/known_hosts` and `allowed_hosts`, with
`MOONHUB_IMPORT_SSH` as the SSH wrapper. Here namespace means the repository's
owner account or team. For GitHub, allow `github.com:22` and verify and pin its
SSH host key. Mirrors do not require or use the namespace's `id_ed25519` import
key. See [SSH setup](../deploy/README.md#ssh-import). HTTPS/token URLs and
arbitrary Git transports are rejected.

The exact normalized host and port must remain in the namespace allowlist.
SSH runs without an agent, with strict host verification and the mirror's key.
The worker rechecks the configuration and the configuring user's active account
and management permission before every transfer. Revoked management access stops
queued work; another manager can save the configuration to take ownership.

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
or credential paths. The transfer timeout uses `MOONHUB_IMPORT_TIMEOUT_SECONDS`.

Prepared reference transactions are recovered under the source write lock after
a process interruption, including branch and tag deletion. Aborted pushes are
ignored. An ambiguous ref requires operator inspection. A worker lost mid-transfer
is retried after its two-hour lease expires; a filesystem lock prevents a live
worker from being duplicated. Temporary snapshots are removed on ordinary exit;
a process killed without cleanup can leave private directories under `.mirrors/`.
Operators may remove abandoned snapshot directories when no mirror worker is active.
