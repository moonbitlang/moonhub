# Package Architecture

The root package contains only the command-line interface and process entry
point. `moon run --strip -j 1 . -- ...` and the deployed executable path are
unchanged.

## Responsibilities

| Package | Owns |
| --- | --- |
| `domain` | Shared account/repository identities, name and path validation, public errors and diagnostic redaction |
| `config` | Environment loading and primitive configuration parsing |
| `database` | SQLite connection/transaction adapter, schema initialization and migrations |
| `gitops` | Git reads, bounded merge operations, revision parsing and filesystem write locks |
| `identity` | Login sessions, accounts, personal namespaces, teams, invitations and profiles |
| `mail` | Delivery settings, transactional outbox claiming and delivery worker |
| `repository` | Repository authorization, registration, provisioning/import jobs, SSH endpoint configuration, durable ref-update events and recovery |
| `collaboration` | Issues, merge requests, reviews, scoped queries, branch rules, versioned check requirements and merge worker |
| `pipeline/workflow` | Bounded GitHub Actions workflow subset, normalized definitions and validation; no database or Web dependency |
| `pipeline` | Authorized run snapshots, push-event consumption, MR check execution, provider grants, atomic claims, leases, logs, cancellation and result persistence |
| `pipeline/protocol` | Versioned runner request/response types and limits; no database or HTTP dependency |
| `provider` | Docker provider claim loop and constrained ephemeral-container adapter; no database dependency |
| `runner` | Single-job process execution, bounded streaming logs, lease watchdog, cancellation and HTTP protocol client; no database or Web dependency |
| `vendor/yaml` | Pinned upstream YAML parser and tests, with the documented bounded-event callback patch |
| `ssh` | SSH keys, authentication, Git transport and trusted receive hook entry points |
| `web` | Application composition, dependency providers and server lifecycle |
| `web/context` | Typed dependency keys, request/session context, authentication, CSRF and request validation |
| `web/ui` | Shared page layout, navigation and reusable presentation |
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
  testkit/
```

Each `views/*` directory has its own `moon.pkg` and tests. Related list, detail,
creation and editing pages live together. Repository browsing and management
share one page package. `views` means the entire page feature, not only its HTML
template. Business services remain outside `web/`.

SQL migrations remain in `db/`; they are deployment data, not a MoonBit package.
Run commands from the module root so migration and fixture paths resolve as
before.

## Dependency Direction

`domain` and `config` have no local package dependencies. `database` and `gitops`
depend on `domain`. `identity` and `mail` use `database` and `domain`.
`repository` composes identity, database, Git and configuration services;
`collaboration` builds on repository authorization. `ssh` uses repository and
collaboration services. `web` is the outer application adapter.

`pipeline/workflow` depends only on `vendor/yaml` and core packages. `pipeline`
uses workflow/protocol definitions, repository/identity authorization, bounded
Git operations, and the database adapter. `web/views/pipelines` owns the machine
API and its HTTP tests. It is mounted independently of browser authentication;
`web/dependencies.mbt` provides its coordinator and `web/server.mbt` owns lease
reconciliation. The independent `runner` package executes assigned literal steps;
the `provider` package claims assignments and invokes Docker; the root package
owns both CLIs. The default Web/SSH services do not include the provider; deploy
it through the dedicated Compose overlay. See
[pipeline delivery scope](pipelines.md).

MR checks add a one-way dependency from `pipeline` to `collaboration`.
Collaboration owns required workflow policies, execution approval, versioned
check records and the merge gate; it does not import Pipeline or the workflow
parser. Pipeline refreshes eligible MRs under the repository write lock, creates
immutable merged-tree runs and cancels obsolete work. Migration 014 links each
run to its check and propagates the latest linked run's state transactionally
through a SQLite trigger. Web owns the check worker lifetime. The two feature
page packages use business APIs and link to each other by URL, never importing
one another. See [MR checks](merge-checks.md) for trust and lifecycle semantics.

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

Repository ref-update events are below Pipeline in the dependency graph. SSH
hooks and the merge worker record them without importing Pipeline. The Pipeline
worker consumes their immutable commit IDs under the shared repository lock and
creates deduplicated workflow runs. Recovery of prepared Git updates happens
before subsequent managed writes, independently of workflow parsing. Web owns
the push worker lifecycle and the repository-level opt-in form.

Rendering functions retain explicit page data arguments. DI is confined to
initialization, not used as a global service locator inside business code.

## Tests

Each production package owns its tests. Run the entire suite or a single
package from the module root:

```sh
moon test --strip -j 1
moon test --strip -j 1 identity
moon test --strip -j 1 repository
moon test --strip -j 1 collaboration
moon test --strip -j 1 web
moon test --strip -j 1 web/views/issues
moon test --strip -j 1 web/views/repositories
```

The shared fixtures create in-memory databases and temporary Git repositories.
Service tests do not need a configured deployment. HTTP tests use ephemeral
loopback ports. Tests retain existing authorization, migration, concurrency,
recovery and error-redaction coverage, plus DI failure/isolation checks and
typed query pagination coverage.

Before committing, run `moon check --deny-warn`, `moon fmt`, and `moon info`, in
that order. Review the generated `.mbti` and formatting changes, then run the
tests and the package-boundary check. The tracked pre-commit hook enforces the
three-command sequence; see [hook setup and index safety](../.githooks/README.md).
