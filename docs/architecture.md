# Package Architecture

The root package contains only the command-line interface and process entry
point. `moon run --strip -j 1 . -- ...` and the deployed executable path are
unchanged.

## Responsibilities

| Package | Owns |
| --- | --- |
| `domain` | Shared account/repository identities, name and path validation, public errors and diagnostic redaction |
| `cli` | Remote collaboration commands, HTTP client, private credential storage and terminal output; no database or Web dependency |
| `cmd/moonhub` | Standalone remote CLI entry point for native builds and Wasm execution through `moonx` |
| `config` | Environment loading and primitive configuration parsing |
| `releases` | Repository versions, immutable published assets, fs/S3 locations and cleanup journals; no Pipeline or Web dependency |
| `storage` | Backend-neutral object storage, filesystem and S3 adapters, bounded streams and integrity checks; no business, database or Web dependency |
| `database` | SQLite connection/transaction adapter, schema initialization and migrations |
| `gitops` | Git reads, bounded merge operations, revision parsing and filesystem write locks |
| `diff/protocol` | Versioned worker/data protocol and resource limits; no Git, Web or database dependency |
| `diff/compute` | Pure MoonDiff calculation and original-file coordinate projection |
| `cmd/moonhub-diff-worker` | One-request isolated diff executable; protocol IO and pure calculation only |
| `identity` | Login sessions, accounts, personal namespaces, teams, invitations and profiles |
| `mail` | Delivery settings, transactional outbox claiming and delivery worker |
| `repository` | Repository authorization, registration, provisioning/import jobs, SSH endpoint configuration, durable ref-update events, recovery and outbound push mirrors |
| `attachments` | Repository-scoped image/file metadata, filesystem storage, inline image conversion, transactional references and pending upload cleanup |
| `webhooks` | Repository webhook configuration, signed delivery, leased retries and history; push capture belongs to repository and event projections to database triggers |
| `collaboration` | Issues, merge requests, reviews, scoped queries, branch rules, versioned check requirements, review requests, transactional notifications and workers |
| `pipeline/actions` | Shared action-reference, path and input-name validation; no execution, database or Web dependency |
| `pipeline/workflow` | Bounded GitHub Actions workflow subset, normalized definitions and validation; no database or Web dependency |
| `pipeline` | Authorized run snapshots, repository CI secrets, public variable snapshots and step delivery, push-event consumption, MR check execution, provider grants, atomic claims, leases, logs, cancellation, workflow OIDC signing/grants, Artifact/Cache v4 metadata, capabilities and storage policy and result persistence |
| `pipeline/protocol` | Versioned runner request/response types and limits; no database or HTTP dependency |
| `provider` | Standalone Docker/ASG controllers, local Tart VM workers, config synchronization and execution cleanup; no database or Web dependency |
| `runner/platform` | OS detection, safe paths, minimal OS environment and private Windows directory ACLs; no database or Web dependency |
| `runner/cli` | Shared single-assignment CLI for the standalone and legacy executable |
| `cmd/moonhub-runner` | Independent runner executable; no Web server or database dependencies |
| `runner` | Single-job process execution, downloaded JavaScript/composite actions, bounded streaming logs, lease watchdog, cancellation and HTTP protocol client; no database or Web dependency |
| `vendor/yaml` | Pinned upstream YAML parser and tests, with the documented bounded-event callback patch |
| `ssh` | SSH keys, authentication, Git transport and trusted receive hook entry points |
| `web` | Application composition, dependency providers and server lifecycle |
| `web/api` | Bearer-authenticated collaboration JSON API, DTO mapping and HTTP tests |
| `web/mcp` | Stateless MCP 2026-07-28 HTTP transport, tool catalog, business-service adapters and HTTP tests |
| `web/context` | Typed dependency keys, request/session context, authentication, CSRF and request validation |
| `web/ui` | Shared page layout, navigation, reusable presentation and HTML/page-response negotiation |
| `web/spa` | Serializable authorized page trees, trusted-template adapter and shared Rabbita document view; native and JS |
| `web/client` | Browser-only Rabbita state, page subscriptions and hydration entry point |
| `web/assets` | Asset manifest, asset tags and static file serving |
| `web/views/*` | Feature-specific routes, request handling, rendering and HTTP tests |
| `test_support` | Disposable database/Git fixtures, mock import transport and SMTP server |
| `web/testkit` | Shared HTTP clients, cookies and application fixtures for Web tests |

The page packages are grouped by feature, not by individual URL:

```text
web/
  app.mbt
  dependencies.mbt
  server.mbt
  context/
  ui/
  assets/
  views/
    auth/
    account/
    namespaces/
    repositories/
    issues/
    merge_requests/
    settings/
    pipelines/
    releases/
    notifications/
  testkit/
```

Each `views/*` directory has its own `moon.pkg` and tests. Related list, detail,
creation and editing pages live together. Repository browsing and management
share one page package. `views` means the entire page feature, not only its HTML
template. Business services remain outside `web/`.

The schema 38 baseline and future SQL migrations live in `db/`; they are
deployment data, not a MoonBit package. Run commands from the module root so
schema and fixture paths resolve. See [database
initialization](../db/README.md).

## Dependency Direction

`domain` and `config` have no local package dependencies. `database` and `gitops`
depend on `domain`. `identity` and `mail` use `database` and `domain`.
`repository` composes identity, database, Git and configuration services;
`collaboration` builds on repository authorization. `ssh` uses repository and
collaboration services. `web` is the outer application adapter.

`pipeline/workflow` depends only on `pipeline/actions`, `vendor/yaml` and core
packages. `pipeline` uses `storage` for object bytes and retains authorization, quotas and cleanup intent metadata.
`pipeline` uses workflow/protocol definitions, repository/identity
authorization, bounded Git operations, and the database adapter.
`web/views/pipelines` owns the machine
API and its HTTP tests. It is mounted independently of browser authentication;
`web/dependencies.mbt` provides its coordinator and `web/server.mbt` owns lease
reconciliation and artifact/cache cleanup. Artifact and Cache Results RPC and signed blob routes
are mounted separately from browser authentication, while durable download links
require repository read access; see [Artifact v4](artifact-v4.md). The independent
`runner` package executes assigned shell steps
and JavaScript/composite actions. The `provider` package owns Docker/ASG
controllers and workers plus the local Tart backend; `runner/cli` owns single-assignment execution arguments,
and `cmd/moonhub-runner` is the standalone entry point. The root package retains
the legacy CLI entry points. The default Web/SSH services do not include a
provider; use the dedicated Compose overlay or standalone controller. See
[Pipeline operation](pipelines.md).

MR checks add a one-way dependency from `pipeline` to `collaboration`.
Collaboration owns required workflow policies, execution approval, versioned
check records and the merge gate; it does not import Pipeline or the workflow
parser. Pipeline refreshes eligible MRs under the repository write lock, creates
immutable merged-tree runs and cancels obsolete work. The baseline schema links
each run to its check and propagates the latest linked run's state
transactionally through a SQLite trigger. Web owns the check worker lifetime.
The two feature page packages use business APIs and link to each other by URL,
never importing one another. See [MR checks](merge-checks.md) for trust and
lifecycle semantics.

Only packages under `web/` import Moonback. Business packages take explicit domain values and
database handles, never HTTP requests, HTML or module contexts. The database's
driver and row representation are opaque outside `database`. Collaboration
queries return typed results; routes and views do not construct SQL or decode
database rows. SQL select fragments and row decoders remain package-private.

Page packages depend on business services and shared Web infrastructure, never
on other page packages or the application composition package in production.
Shared rendering belongs in `web/ui`, not in a sibling page package.

Production packages never import `test_support` or `web/testkit`. Tests import
these fixtures with `for "wbtest"`; `web/testkit` itself reuses the lower-level
`test_support` fixtures. Business tests do not import Web packages or start an
HTTP server. Tests that exercise routes, cookies, CSRF or HTML live beside their
page feature, even when they span services. HTTP fixtures can compose the full
application to exercise integrations without coupling production page packages.

Check the compiler-resolved graph (including test import kinds) with:

```sh
node scripts/check-package-boundaries.cjs
```

The allowlist in that script makes dependency direction explicit. Update it
deliberately when introducing a package or changing an architectural boundary.

## Web Initialization

Web features are `Module` values, not factories accepting shared parameters.
The main app initializes `browser_resources_module` and `services_module`
before installing feature modules:

1. Bootstrap configuration supplies repository/assets roots, the existing
   database handle and optional SSH/import settings.
2. Providers load the asset manifest once per main app and publish dependencies
   with `ModuleContext::provide`.
3. Each feature calls `require` during initialization and captures the resulting
   dependencies in its handlers. Only optional import settings use `resolve`.
4. `BrowserAccess` groups the repository visibility and authorization policies.
   Production providers enforce the database-backed policy; browser fixtures
   explicitly inject a test policy. There is no permissive production default.

Dependencies are app-scoped. Mounted static assets and the main application
have separate Moonback containers, so their composition roots initialize their
own resources. Only these composition roots read custom bootstrap config.
The server owns database and worker lifetimes; providers borrow the database
and never close it.

Structured diff uses an application-scoped `gitops.DiffExecutor`, registered at
the Web composition boundary and required by feature/API/MCP modules. Gitops
loads fixed comparison manifests and bounded blobs, and runs the standalone
worker under deadlines and cancellation. It imports only `diff/protocol`;
MoonDiff calculation stays out of the server process. Shared rendering lives
in `web/ui`; session endpoints remain in the MR/repository feature packages.
Inline comment preparation happens before repository locking, then the write
section rechecks authorization and immutable revision identity. See
[Structured diff](moondiff.md) for the protocol, limits and runtime configuration.

Repository ref-update events are below Pipeline in the dependency graph. SSH
hooks and the merge worker record them without importing Pipeline. The Pipeline
worker consumes their immutable commit IDs under the shared repository lock and
creates deduplicated workflow runs. Recovery of prepared Git updates happens
before subsequent managed writes, independently of workflow parsing. Web owns
the push worker lifecycle and the repository-level opt-in form.

Permanent deletion belongs to `repository`: it takes the shared Git write lock,
rechecks the immutable repository ID and current manager permission, refuses
unfinished CI runs/attempts and syncing mirrors, and transactionally records a
cleanup manifest before deleting the repository. Foreign keys remove business
records and delivery retries; deploy-key tombstones remain revoked. The manifest
has no foreign key to the deleted repository and reserves its namespace/name
until storage cleanup succeeds. A database trigger enforces this reservation for
all registration paths.

The Web server starts the durable cleanup worker with storage callbacks supplied
by `attachments` and the application-scoped Pipeline coordinator. Repository owns
Git and mirror cleanup, so it does not import either higher-level package.
Artifact/cache cleanup uses the destinations preserved by the cascade deletion
journal, including historical filesystem and S3 locations. It retains delayed
namespace intents to reclaim uploads that finish after the initial cleanup.
Cleanup uses a shared-volume worker lock, rejects traversal and filesystem
symbolic links, treats missing files as successful retries, and retries failures
after 30 seconds, including after restart.
Attachment uploads share the repository write lock; local imports keep their
source ID and hold its lock through cloning/publication. Managed writes and SSH
transport compare repository IDs before and after acquiring the lock.

Push mirror configuration, ref intents, snapshotting and delivery workers belong
to `repository`; `web/views/repositories` owns the authorized settings forms.
The source write lock covers only the local snapshot; a separate per-mirror lock
serializes external transfers and configuration changes. Per-mirror keys and the
per-mirror destination host-key pins and pending fingerprint confirmations live
in the database. Repository managers initialize and explicitly confirm each
destination before enabling sync. Mirror transport
settings are independent of SSH import configuration; transfer-only credential
files are generated and cleaned by the worker. See [push mirrors](mirrors.md).

The browser rendering boundary is described in [frontend architecture](frontend.md).
`web/spa` has no business or HTTP dependency. It holds only presentation data;
`web/client` never imports server or business packages. Existing feature templates
remain server-owned during migration, while both initial rendering and later
navigation use the same Rabbita document view. Both targets use the published
Rabbita version declared in `moon.mod`, including its public attribute escape hatch.

Rendering functions retain explicit page data arguments. DI is confined to
initialization, not used as a global service locator inside business code.

## Tests

Each production package owns its tests. Run the entire suite or a single
package from the module root:

```sh
npm ci --prefix runner/actions --ignore-scripts
node --test runner/actions/runtime.test.mjs
npm ci --prefix js
npm run build --prefix js
moon test --strip -j 1
moon test --strip -j 1 identity
moon test --strip -j 1 repository
moon test --strip -j 1 collaboration
moon test --strip -j 1 web
moon test --strip -j 1 web/views/issues
moon test --strip -j 1 web/views/repositories
```

The frontend build generates the ignored `assets/` directory and icon CSS.
Web tests need these assets; build them after cloning and rebuild after changing
frontend sources or dependencies. Business package tests do not need them.

The shared fixtures create in-memory databases and temporary Git repositories.
Service tests do not need a configured deployment. HTTP tests use ephemeral
loopback ports. Tests retain existing authorization, migration, concurrency,
recovery and error-redaction coverage, plus DI failure/isolation checks and
typed query pagination coverage.

Before committing, run `moon check --deny-warn`, `moon fmt`, and `moon info`, in
that order. Review the generated `.mbti` and formatting changes, then run the
tests and the package-boundary check. The tracked pre-commit hook enforces the
three-command sequence; see [hook setup and index safety](../.githooks/README.md).

Collaboration owns review requests, subscriptions, event fan-out and Inbox
queries. Database triggers create notifications and optional email outbox rows
transactionally with activity; the mail worker rechecks current
access/preferences at claim time. `web/views/notifications` owns Inbox routes
and HTTP tests. Web starts the review request refresh worker independently of
Pipeline so ready MRs without CI refresh in the background. Shared subscription
rendering lives in `web/ui`.

The remote CLI uses `/-/api/v1`, mounted separately from browser cookie/login
middleware and Runner credentials. Identity owns scoped, expiring access tokens;
`web/views/account` owns their CSRF-protected creation/revocation pages. API
mutations reuse business services and repository locks. The API never implicitly
authorizes code execution when creating an MR with a collaboration write token.

`web/mcp` is an outer adapter mounted at `/-/mcp`, independently of browser
middleware. It obtains database, repository root, Pipeline coordinator and origin
policy through `ctx.require`, and calls business services directly. It shares
JSON DTO mapping with `web/api`; business packages do not import MCP. The
composition boundary reads `MOONHUB_MCP_ALLOWED_ORIGINS`. No Runner credentials
are converted into MCP credentials. See [MCP](mcp.md).

Release lifecycle and byte storage belong to `releases` and `storage`; Pipeline grants only live repository-scoped job API capabilities. The Web adapter composes these services without business packages importing one another. `web/views/releases` owns browser pages and downloads; `web/api` owns the bounded gh-compatible API. See [releases](releases.md).
