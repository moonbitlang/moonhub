# Artifact v4 compatibility

MoonHub executes the downloaded upstream `actions/upload-artifact@v4` and
`actions/download-artifact@v4` code. Migration 032 adds the backing service,
private filesystem storage and attempt-scoped credentials. Deploy the updated
server and runner together. The runner lease/report protocol remains V1;
existing assignment and workflow snapshots remain readable.

## Supported workflow behavior

Within one workflow run, jobs can upload named immutable ZIP artifacts and later
jobs can list and download them. The original Actions implement file selection,
compression, hidden-file handling, `if-no-files-found`, output generation,
`overwrite: true`, download by name or ID, `pattern` and `merge-multiple`.
MoonHub provides the service these Actions contact. The service verifies the
uploaded ZIP's byte count and SHA-256 before publishing it. Pending and partially
uploaded artifacts are not listed or downloadable.

The runtime implements these Results Twirp JSON RPCs at the root path
`/twirp/github.actions.results.api.v1.ArtifactService/`:

- `CreateArtifact` returns a signed upload URL.
- `FinalizeArtifact` verifies the archive size/digest and publishes its identity.
- `ListArtifacts` returns finalized, unexpired artifacts in the current run.
- `GetSignedArtifactURL` returns a short-lived download capability.
- `DeleteArtifact` tombstones an artifact, allowing upstream overwrite behavior.

Upstream v4 uses the Azure Blob SDK for its data transfer. MoonHub implements the
necessary Block Blob HTTP subset: stage a block with `PUT ?comp=block`, commit
an ordered `<BlockList>` with `PUT ?comp=blocklist`, and download with `GET`.
A repeated stage replaces its block and releases the old file; replaying the same
committed block list is idempotent. Reordering a committed list is rejected.
This protocol compatibility does not require an Azure account or Azure storage.
The service stores opaque ZIP bytes under `<repository-root>/.pipeline-artifacts/`
with random paths and private directory/file permissions.

## Credentials and isolation

A running native execution obtains a distinct credential from
`POST /-/runner-api/v1/attempts/:id/artifact-runtime`, authenticated with its
lease credential and bound execution ID. The credential is JWT-shaped because
the upstream toolkit decodes `scp=Actions.Results:<run>:<attempt>`; MoonHub
validates the hash of the entire opaque credential and never trusts its claims.
Neither this credential nor blob capabilities authorize runner control or
repository APIs. Only hashes are stored in their credential tables.

Every RPC and blob request rechecks the issuing execution, lease, deadline,
cancellation, provider grant and repository authorization. The runtime can read
artifacts produced by other jobs in the same run; caller-supplied producer IDs
cannot widen its scope. Writes require the producing attempt. Runtime credentials
expire after at most one hour, or at the execution deadline, whichever is sooner.
Blob capabilities expire after ten minutes and remain subject to the live runtime
checks. Completing or canceling an attempt invalidates its access immediately.
Later jobs receive their own credentials. Streaming downloads recheck access
between chunks.

Credentials are delivered privately to the action runtime, masked in its logs,
and excluded from child-facing `MOONHUB_ACTION_*` variables. Child JavaScript
Actions receive `ACTIONS_RUNTIME_TOKEN` and `ACTIONS_RESULTS_URL`. Workflow env
and file commands cannot replace these reserved service variables. Post handlers
receive a fresh runtime grant while their execution remains live.

The upstream v4 toolkit rejects non-GitHub server hostnames. While executing the
JavaScript Action entry point with a Results service grant, the runner supplies
its supported localhost compatibility identity,
`GITHUB_SERVER_URL=http://moonhub.localhost`. The original downloaded executable
code is unchanged. `ACTIONS_RESULTS_URL` still points to the real MoonHub origin;
`github.server_url` expressions retain that origin. Embedded cache consumers use
the same compatibility identity, and the local source Git redirect recognizes it.
The
runner canonicalizes artifact download links in logs and `artifact-url` outputs
back to MoonHub's authenticated
`/<owner>/<repo>/actions/runs/<internal-run-id>/artifacts/<artifact-id>` route.
This link continues to work for authorized repository readers after the job ends.

## Limits and lifecycle

The initial limits are 512 MiB per ZIP, 8 MiB per staged block, 64 blocks per ZIP,
4 GiB of staged bytes per run, and 500 stored artifact records per run. Deleted
records/blocks still consume quota until their files are removed. Retention
is seven days by default and at most 90 days; the original Action handles its
`retention-days` input. Each attempt can have at most 128 live runtime grants
and 4,096 unexpired signed capabilities across those grants.

The Web worker reaps expired and deleted artifacts once a minute, at most 100
records per sweep. It also removes incomplete uploads older than one hour whose
producer attempt has completed, expired runtime credentials/capabilities, and
unreferenced storage directories left by run/repository deletion. Artifact
access expires immediately even if physical deletion is queued. Staged blocks
and the assembled archive coexist until cleanup; allow up to twice the staged
byte quota plus in-flight upload space (four concurrent blob transfers per Web
process) on the Web data disk. Transfer-slot waits, response headers and each
response-body write are bounded to 30 seconds. Authorization is rechecked after
a slot becomes available and before every downloaded chunk, including browser
downloads. Existing whole-data-volume backups include the
artifact directory.

This increment supports the v4 current-run protocol. Cross-run/cross-repository
GitHub REST downloads using the Action's `github-token` input fail explicitly;
GitHub API token compatibility is separate work. Cache v4 has its own Results
service; see [Cache v4](cache-v4.md).
Release/OIDC APIs remain separate work. An interrupted pending upload reserves
its name until cleanup; upstream overwrite can replace finalized artifacts, but does not
list or remove incomplete uploads. This implementation does not expose arbitrary
Azure Storage APIs, containers or accounts.

## Validation

Offline regression includes business authorization/lifecycle tests, the HTTP
Twirp/Block Blob contract, production browser authorization and native runner
credential/file-command handling:

```sh
node --test runner/actions/runtime.test.mjs
npm run build --prefix js
moon test --strip -j 1
node scripts/check-package-boundaries.cjs
```

Opt-in acceptance downloads pinned, unmodified upstream upload v4.6.2 and download
v4.3.0, executes them against a disposable real MoonHub HTTP server and gives
producer and consumer separate attempts/workspaces:

```sh
MOONHUB_ARTIFACT_UPSTREAM=1 \
MOONHUB_ARTIFACT_NODE20=/absolute/path/to/node20 \
moon test --strip -j 1 web/views/pipelines --filter '*Artifact*'
```

The Node 20 override selects the upstream Action's declared runtime; without it
the smoke uses the locally installed Node binary. Acceptance covers a 9 MiB ZIP
that spans blocks, retention, hidden files, overwrite and outputs, ignored missing
files, cross-job pattern/merged downloads, downloads by name and ID, and byte
equality.
The smoke runs real third-party executable code and needs public GitHub access;
the normal test suite does not require that network access.
