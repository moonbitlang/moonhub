# Cache v4 compatibility

Storage can use filesystem or S3 independently for artifacts and caches; see [blob storage](blob-storage.md) for configuration, cutover and cleanup.

MoonHub downloads and executes the original actions/cache@v4, cache/restore,
cache/save and cache clients embedded in JavaScript Actions. The baseline schema
backs Cache Service v2 (the protocol used by Cache Action v4). There is no
built-in cache Action replacement. Deploy the updated server and runner
together; the runner/report protocol remains V1 and existing snapshots remain
readable.

## Workflow behavior

The original Action selects paths, computes archive versions, creates/extracts
tar archives, handles compression and cross-OS options, sets outputs and saves
in its post handler. MoonHub implements the Results Twirp JSON methods at
/twirp/github.actions.results.api.v1.CacheService/:

- CreateCacheEntry reserves an immutable key/version in the current scope and
  returns an upload capability. Repeating a pending reservation from the same
  attempt is idempotent; competing writers cannot replace it.
- FinalizeCacheEntryUpload verifies the completed byte count before publication.
  Retrying finalization is safe; partial uploads stay invisible to restores.
- GetCacheEntryDownloadURL searches the primary key, then restore keys in order.
  For each key, exact matches precede prefix matches; the newest prefix wins.
  Archive versions must match exactly. A miss returns ok: false.

The data path reuses private Artifact storage and Block Blob HTTP compatibility.
Cache adds single PUT (used by the SDK for archives up to 128 MiB), larger staged
blocks, and safe replay of identical committed blocks. No Azure account or Azure
storage is required: the downloaded SDK talks to MoonHub. Its non-Azure download
path uses ordinary GET. Cache entries do not appear in Artifact RPCs or browser
Artifact downloads.

The runtime sets ACTIONS_RUNTIME_TOKEN, ACTIONS_RESULTS_URL, ACTIONS_CACHE_URL
and ACTIONS_CACHE_SERVICE_V2=true. Workflow env and file commands cannot replace
these reserved variables. JavaScript Actions with a service grant receive the
toolkit-supported GITHUB_SERVER_URL=http://moonhub.localhost identity, including
tool setup Actions that embed the cache library. Expressions retain the actual
github.server_url; API and Results URLs point to MoonHub. The local source Git
redirect recognizes both identities, preserving immutable-source checkout.
Artifact links are canonicalized back to the authenticated MoonHub URL.

## Authorization and branch scope

Cache uses the distinct execution-scoped Artifact runtime grant, never the
runner lease credential. Every RPC and blob request rechecks execution, lease,
deadline, cancellation, provider grant and repository authorization. Completing
a producer revokes its credentials, while finalized data remains available to
future authorized executions with their own grants. Uploads require the
producing attempt/current scope; downloads bind to the consuming runtime.
See [Artifact v4](artifact-v4.md) for grant lifetimes and transfer controls.

The server captures current, base and default scopes when creating a run.
Branch push/manual runs write to their branch. MR runs write only to their
synthetic refs/pull/<internal-MR-id>/merge scope. Restores search current scope,
then the MR base branch, then repository default, removing duplicates. MR caches
cannot poison trusted branches or be read by sibling MRs. Caller metadata never
selects scope. Reruns copy the original snapshot even if defaults change. Older
runs without a captured scope fail closed. Tag triggers and cross-repository
caches are separate work.

## Limits and lifecycle

- Archive: 512 MiB; block or single PUT: 128 MiB; blocks per archive: 64.
- Repository quota: 10 GiB of staged cache bytes, separate from Artifact quota.
  New uploads evict the least recently accessed finalized entries when space is
  needed. Another upload cannot evict pending entries.
- At most 1,000 live entries and 100 pending reservations per repository. At the
  live-entry limit, creation evicts the least recently used finalized entry.
  Up to 100 deleted records can await cleanup; further reservations fail until
  physical cleanup frees record capacity.
- Pending uploads expire after one hour. Finalized entries expire seven days
  after their last successful lookup; lookup refreshes the deadline.
- Keys: 512 UTF-8 bytes; archive versions: 256 bytes; at most ten primary/restore
  keys per request. These limits can be lower than GitHub's service limits.

The existing once-per-minute cleanup reclaims expired/deleted cache objects and
metadata, up to 100 entries per sweep. Deleted blocks consume quota until their
files are removed. Blocks coexist with assembled archives: provision up to
twice the staged quota plus Artifact storage and in-flight buffers. Four blob
transfers are allowed per Web process; each cache upload can buffer 128 MiB.
Repository deletion cascades cache metadata; deleting a producer run/attempt
currently also cascades its caches. Whole-data-volume backups include fs storage. S3 object recovery is managed
separately; see [blob storage](blob-storage.md).

## hashFiles expressions

Runtime expressions support hashFiles(pattern, ...) in step inputs, env,
scripts, conditions and composites. Matching uses the pinned Actions toolkit:
hidden files, implicit descendants, ordered ! exclusions, escaped glob literals
and Windows case folding. Each matched file is SHA-256 hashed, then the binary
digests are concatenated and SHA-256 hashed. No match returns an empty string.
Asynchronous evaluation preserves lazy conditions. Scheduling/matrix expressions
cannot access a workspace.

Traversal and symlink targets stay inside the workspace; outside/broken links
and cycles are skipped. Per call: 100 patterns, 64 KiB pattern text, 100,000
visited entries, 10,000 matched files and 512 MiB content. Differential tests
verify toolkit matching and digest order. Runner images/bundles must install
the updated npm lockfile.

## Validation

Offline tests cover exact/version/prefix selection, incomplete uploads,
immutable retries, cancellation, completed-producer access, MR/trusted scope
separation, rerun snapshots, LRU/expiry, baseline defaults, single PUT and
staged blocks. JavaScript tests compare hash/glob semantics with the pinned
toolkit, exercise input delivery, and bound subdirectory Action entry points to
their repository root.

Opt-in HTTP acceptance downloads and executes unmodified actions/cache@v4.2.4,
pinned to 0400d5f644dc74513175e3cd8d07132dd4860809. It covers post save, a 9 MiB
incompressible payload, exact/prefix restore, lookup-only, version misses and
immutable re-save using separate job credentials. The same acceptance also runs
unmodified actions/setup-node@v4 with npm caching and verifies a restored marker
in the next job, covering its embedded cache client. Run:

    npm ci --prefix runner/actions
    npm ci --prefix js
    npm run build --prefix js
    node --test runner/actions/runtime.test.mjs
    moon test --strip -j 1
    MOONHUB_CACHE_UPSTREAM=1 moon test --strip -j 1 web/views/pipelines --filter '*Cache*'

Use MOONHUB_CACHE_NODE20=/absolute/path/to/node for Node 20 upstream entry points.
Legacy Cache Service v1 is not implemented; v1-only clients need newer Actions.
