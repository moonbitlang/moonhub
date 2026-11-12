# Releases and published assets

Releases are repository versions with an immutable commit identity, notes and
independent downloadable assets. They do not expire with a CI run. Pipeline
artifacts remain temporary build handoffs; publishing uploads their extracted
files into the release service rather than retaining an expiring artifact ID.

## Lifecycle and authorization

Repository writers create drafts. Readers see published versions; only writers
see drafts. Draft asset names are unique: `gh release upload --clobber` removes
the old draft asset and uploads a new immutable generation. A failed replacement
leaves the draft incomplete and can be retried. Uploads stream in 8 MiB chunks,
verify complete SHA-256 and size, and allow at most 2 GiB per asset, 100 live
assets per release and two concurrent transfers per Web process. Empty assets
are rejected. Uploads have a ten-minute deadline; each download read/write and
transfer admission has a thirty-second deadline.

Publishing verifies that no pending or old-target assets remain, creates or
checks the Git tag at the exact saved commit, and exposes the release in a
single database update. The repository write lock serializes publication and
target changes. An interrupted publication can be retried against the same tag
and commit. Private refs retain draft commit objects. Published release metadata,
assets and tags cannot be edited or deleted through these APIs or managed Git
pushes. `make_latest: "true"` can select an existing stable version, including an
older release for rollback; prereleases cannot become latest. An external app's
latest-version manifest is a separate publication action.

Downloads always pass through MoonHub authorization and are rechecked before
headers and between chunks. Public published assets can be downloaded without
login. Private repositories and drafts require their corresponding access.
No S3 credential or object URL is exposed to a runner or browser.

## Storage, recovery and deletion

The existing `MOONHUB_STORAGE_CONFIG` optionally accepts `releases`, selecting a
named backend independently of artifacts/caches. Omit it to use the configured
artifact backend. With no storage config, release bytes live under
`ROOT/.release-assets`, separate from the legacy CI artifact directory. Each
asset uses a `release_` namespace (excluded from legacy CI orphan scanning) and saves the complete fs/S3 destination so changing defaults preserves old
reads, downloads and cleanup.

Every upload starts with a durable pending namespace reservation. Cancellation
or failure retains a tombstone, and pending uploads expire after twenty minutes.
Successful finalization records individual staging-part deletion intents in the
same transaction; only the canonical archive remains after cleanup. Asset/draft
or repository cascades create namespace cleanup intents that survive metadata
removal and wait ten minutes before deletion. The cleanup worker removes objects
and unfinished multipart uploads and retries failed destinations after one minute.
It does not apply a time-based expiry to published assets.

Schema 040 also stores live job API grants, immutable run display titles and
opt-in schedule configuration. Upgrade Web, SSH, controllers and runners together.
Database rollback requires the matching backup; do not downgrade the binary
against schema 040. Local volume backups cover the database and default fs root;
S3 objects require an independent recovery policy coordinated with database
backup retention. Existing deployment identity isolation remains unchanged.

## Canonical origin and proxy

Set `MOONHUB_RELEASE_ORIGIN=https://moonhub.example` before using the JSON release
API. Responses construct upload/download URLs from this configured HTTPS origin,
never an untrusted Host header. The Compose Web environment and recovery settings
preserve it. Browser pages work without this API setting. Anonymous downloads
still enforce repository visibility.

An operator-managed proxy must allow large uploads only on the authenticated
release asset route, with request buffering disabled. For example:

```nginx
location ~ ^/api/v3/repos/[^/]+/[^/]+/releases/[0-9]+/assets$ {
    client_max_body_size 2g;
    proxy_request_buffering off;
    proxy_read_timeout 600s;
    proxy_send_timeout 600s;
    proxy_pass http://127.0.0.1:8080;
}
```

Preserve the existing TLS/proxy headers and application limits. Apply the same
bounded rule to `/-/api/v1/repos/.../releases/ID/assets` if clients use that native
API prefix. This PR does not change a production proxy or publish a real release.

## APIs and the original gh CLI

The release REST subset is available under `/-/api/v1` and the GitHub enterprise
compatible `/api/v3` prefix:

- `GET/POST /repos/OWNER/REPO/releases`
- `GET /repos/OWNER/REPO/releases/latest` and `/releases/tags/TAG`
- `GET/PATCH/DELETE /repos/OWNER/REPO/releases/ID` (DELETE is draft-only)
- `POST /repos/OWNER/REPO/releases/ID/assets?name=FILE&label=LABEL`
- `GET/DELETE /repos/OWNER/REPO/releases/assets/ASSET_ID`
- `GET /repos/OWNER/REPO/release-assets/ASSET_ID/download`

JSON metadata includes numeric IDs, `upload_url`, `browser_download_url`, sizes
and server-computed `sha256:` digests. Octet-stream asset GET returns the bytes.
The limited `/api/graphql` `RepositoryReleaseByTag` lookup serves gh's draft
resolution; this is not a general GraphQL endpoint. Unsupported fields/operations
fail explicitly. Existing user tokens require `read` or `write` respectively.

Configure a normal gh host login for a person; never pass a token in argv. Inside
jobs MoonHub installs a private host-specific gh profile for each invocation and
sets `GH_HOST`, so unchanged `gh release`/`gh api` commands use the MoonHub host.
Tested commands include create draft, upload/clobber, download, edit/publish,
latest and paginated list. A real gh integration test runs over an isolated Unix
socket without contacting GitHub, changing system certificate trust or publishing
outside its temporary repository.

## Job permissions

`permissions.contents` supports `none`, `read` and `write`; `permissions.actions`
supports `none` and `read`. An explicit permission map resets unspecified rights.
Jobs that explicitly grant contents read/write or actions-read require assignment version 12; older runners reject
this contract rather than substituting an empty token. Jobs that rely only on the historical default retain their
historical assignment behavior. `github.token` receives an opaque job credential
only when API permissions are declared. It is repository-bound, tied to the live
attempt/execution, masked in logs and invalid after cancellation, lease expiry,
completion or permission revocation. Write APIs additionally reject MR runs and
untrusted trigger contexts. These grants cannot authenticate to collaboration,
user account, runner or other repositories' APIs.

The gh profile contains only this host's token and is removed after pre/main/post
or script invocation. When `GH_TOKEN: ${{ github.token }}` is explicitly supplied,
the runtime uses the host-specific profile instead of exporting a credential that
gh might send to a different enterprise host. Explicit external-service secrets
remain distinct and do not become MoonHub job credentials.

## Schedules and run history

`on.schedule` supports five-field numeric UTC cron expressions with ranges,
lists and steps. No aliases or named weekdays are accepted. Schedules are off by
default even when workflow source declares them. A repository manager enables
execution with an execute-scoped API token:

```text
POST /-/api/v1/repos/OWNER/REPO/schedules
Content-Type: application/json
{"enabled":true}
```

GET on that route returns the configuration and sanitized last error. The actor
who enables it must remain active and authorized. The worker scans current UTC
minutes on the default branch, takes immutable snapshots, and deduplicates each
workflow/minute through the repository lock and a unique database key. Restart
and overlapping scans cannot create duplicate runs for a tick. Missed minutes
while the service is down are not replayed. Disabling schedules stops future
runs; cancellation of an existing run remains explicit.

`run-name` supports the bounded expression engine's github/inputs contexts and
is captured as a display title, separate from the workflow's stable name.
`GET /api/v3/repos/OWNER/REPO/actions/workflows/FILE/runs` exposes authorized
history, including `head_sha`, `head_branch`, `display_title`, status and
conclusion, and requires `actions: read` for job credentials.

Release support does not yet claim full openseek publication: platform tool
inventory, cold Windows preparation, Apple signing/notarization, external OSS/S3
release credentials and openseek's public API deployment must each be configured
and verified. The pinned application repository and original workflows remain
unchanged.
