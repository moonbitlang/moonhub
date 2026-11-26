# CI capability implementation evidence

This records implementation of the approved 39-issue plan. Each category is a
separate commit on one development branch. Only completed acceptance qualifies
an issue for a closing reference in the final PR.

## Expression and YAML compatibility

- #117: retained the existing missing-matrix string conversion fix and its
  function and selected-step regression tests in `runner/actions/runtime.test.mjs`.
- #118: output syntax/context validation is separate from runtime evaluation;
  `join`, JSON conversion and relational operators are accepted. The HTTP dataflow
  fixture checks output publication and consumption by dependent jobs.
- #119: scheduler and runner consume the same literal-index fixture. Whole
  `runs-on` expressions preserve arrays and reuse existing label validation.
- #88: aliases share scalar, mapping and sequence values. The event guard rejects
  recursive/undefined references and charges expanded nodes, depth and scalar
  bytes before loading. Tests compare anchored and inline plans and reject bombs.

Validation: workflow tests 68/68; Runner JavaScript tests 46/46; browser assets
built; required check/format/interface sequence passed with the production pin.
The HTTP suite passed 26/26 with Git 2.48.1, including real Runner output
dataflow and merged checkout. The system Git 2.34.1 is too old for that suite.
New indexed templates require assignment v14; old snapshots retain their saved
runtime requirement. Providers and Runners must be upgraded together.

## Shell and runner selection

- #72: syntax validation stays in planning; OS compatibility follows step
  conditions in the runtime and native assignment validation accepts those
  conditional plans. The HTTP dataflow fixture includes a skipped PowerShell step.
- #93: `cmd` works through step/workflow/job defaults and composite execution.
  Windows tests cover spaced workspace paths, batch environment/output files and
  nonzero exit codes. They require the Windows CI runner and are skipped locally.
- #73: `ubuntu-22.04-arm` requires Linux ARM64 and Ubuntu 22.04. Scheduler tests
  reject x64 providers. No real ARM64 compilation/packaging has been executed.
- #89: schema 49 adds administrator-maintained groups, provider membership and
  repository grants. Assignment intersects all group, provider and label rules;
  live authorization rechecks grants. Administration forms enforce CSRF and
  optimistic revisions; scheduler tests cover restart and revocation.

Validation: affected MoonBit suites passed 313/313 (workflow, migrations,
scheduler, pipeline administration and Runner HTTP); JavaScript passed 47,
with 7 Windows-only tests skipped on Linux. Required check/format/interface
commands passed with the production compiler pin.

## Events and run attempts

- #70: definition v9 persists bounded event payloads with the immutable run.
  PR concurrency uses the saved number and head/base SHAs; push events retain
  before/after and ref. Conditions, runner expressions and event files share it.
- #107: schema 50 adds stable public IDs and monotonically increasing workflow
  attempts, separate from worker attempts and historical run record numbers.
  Assignment v15 exposes the stable ID/attempt to runner context and environment.
  API history and run pages link previous attempts; OIDC uses the public identity.
- #108: failed-only reruns compute the failed/dependent closure transactionally,
  reference unaffected saved outputs/conclusions, and retain pinned source/events.
  CLI, API and forms expose the operation. Reused logs/artifacts stay with their
  original attempt; same-run artifact RPC authorization is unchanged.

Validation: the broad native run exercised 739 tests. Its five failures were
four obsolete protocol expectations and a PR-number JSON typing bug; affected
native files then passed 60 tests, and the corrected CLI flag passed 11/11.
JavaScript passed 48, with 7 Windows-only tests skipped. Required check, format
and interface commands passed. The final full-suite run remains required after
all categories are implemented.

## Trigger extensions

- #74: pushed tags, including annotated tags, select workflows through tag filters
  and retain tagged commit/ref snapshots. Branch/path semantics remain distinct.
- #75: first stable/prerelease publication supports `published`; `released`
  defaults remain stable-only. Retry/draft/authorization behavior stays bounded.
- #76/#77/#79: schema 51 persists completion, repository dispatch and explicit PR
  lifecycle events. Per-workflow deduplication survives restart; completion chains
  stop after three levels. Dispatch requires execute authority on both API mounts.
  Lifecycle runs are independent of merge gates and retain closed/merged metadata.
- #80: schedules use installed IANA TZIF data. Deterministic fixtures verify UTC,
  UTC+08:00, spring-gap advancement and first-only autumn overlaps.

Validation: parser/timezone/migration tests passed 100/100; trigger, HTTP,
secret-policy and migration integration tests passed 44/44; the final lifecycle
and tag tests passed 5/5. Package boundaries passed for 56 packages, and the
base-image cache/build regression passed. Required check/format/interface steps
passed. No production image was built or deployed.

## Dynamic matrices and scheduling

- #81: deferred matrix templates retain the original workflow snapshot. Schema 52
  stores evaluated matrices and child definitions transactionally; invalid data
  fails the consumer with a visible diagnostic. Expanded jobs retain event-resolved
  values, provider checks, output ordering and shared job/step/byte budgets.
  Duplicate completion, restart and failed-only child reuse have regression tests.
- #83: job failure policies preserve actual failures while dependencies, fail-fast
  and run summaries use effective results. API and run pages expose both results.
- #84/#85: workflow/job groups share durable repository-scoped admission. Default
  pending replacement remains; `queue: max` admits 100 waiters in FIFO order and
  cancels new overflow. Cancellation holds capacity until fencing. Job queues wait
  for dependencies and workflow admission, leaving unrelated jobs eligible.

Validation: native scheduling, workflow, outputs and migration tests passed
128/128; the additional job FIFO/restart case passed 1/1, and final JSON bound
cases passed 4/4. API/page tests passed 7/7; JavaScript runner tests passed 49/49.
Browser assets, TypeScript checks and native builds passed. The Actions/run-detail
browser regression passed 1/1 using installed Chromium 1234 and an isolated port;
the initial attempts encountered an occupied default port and absent Chromium 1248.
Required check/format/interface commands passed. No cloud execution was performed.

## Local reusable workflows

- #71: local callees are read from the caller's pinned commit and included in the
  immutable definition. Declared string/number/boolean inputs, nested calls,
  outputs and dependency closures retain the shared job, step and byte budgets.
  Callee permissions intersect caller permissions; cycles and unsupported remote
  refs fail before execution. Successful calls can be reused on failed-only reruns.
- Schema 53 persists call expansion and outputs. Cancellation keeps group capacity
  until active children are fenced. Output aggregation retains bounded secret
  fingerprints after raw credential cleanup, including across reused attempts.

Validation: reusable workflow and migration tests passed 40/40. Earlier workflow,
output, scheduling and migration regressions passed 136/136; cancellation
regressions passed 38/38. Fixtures cover nested/dynamic calls, moved branches,
permission reduction, typed concurrency, duplicate completion and reconstructed
secret suppression. The repository's unchanged CI workflow parses with its local
frontend callee. Actual platform scripts and deployment were not executed here.

## Deployment environments

- #99/#100: schema 54 stores stable target identities, immutable public snapshots,
  per-job admission and review history. Dependencies/conditions precede review;
  job concurrency and runner assignment follow it. Reviews bind the workflow
  attempt, environment and policy revision. Restart, stale decisions, deletion,
  reviewer revocation, rejection and cancellation have regression coverage.
- #101/#102: environment secrets and execution-time variables override repository
  names. Reruns retain captured public values and recheck current approval and
  secrets. Credentials stay out of assignments/read models; raw delivery cleanup
  and log/output masking remain shared. Deleting an environment secret cannot
  expose its cached value through a repository fallback.
- Management/review APIs share both mounts; settings and run pages enforce CSRF
  and business authorization. No administrator approval bypass is introduced.

Validation: affected parser, scheduling, reusable-workflow, credential, migration
and HTTP suites passed 150/150. TypeScript and browser asset builds passed;
package boundaries passed for 56 packages. Native build and both browser checks
passed (environment settings and Actions navigation). Required check, format
and interface commands passed. The deployment environment declaration
from the repository's `deploy.yml` is covered by an equivalent planning fixture.
The complete GitHub script still uses intentionally reserved `MOONHUB_DEPLOY_*`
variables; their namespace protection is retained. No cloud target was configured
and no deployment was performed.

## Linux container execution

- #90/#91/#92: assignment v16 carries bounded job/service plans. Schema 55 and
  live authorization restrict claims to explicitly isolated, controller-armed,
  one-use Linux CI workers. Labels and ordinary providers cannot enable Docker.
- Job shells and JavaScript actions share workspace and command files; services
  use a dedicated network, aliases, loopback ports and bounded health checks.
  Docker metadata/actions support inputs, Dockerfiles, entrypoints and outputs.
  Host-control options and workflow-selected Docker client settings are rejected.
- Cleanup covers partial startup and every terminal path, runs outside cancelled
  step groups, and preserves the provider's final isolation fence. Unverified
  cleanup reports lost. See `docs/workflow-containers.md` for image requirements
  and the explicit metadata-action capability selection.

Validation: parser, provider isolation, runner and migration suites passed
165/165; JavaScript runtime/container tests passed 55/55. Package boundaries
passed for 56 packages. The existing real Docker CI script now covers PostgreSQL
connectivity, Docker action inputs/outputs and cleanup before success, failure,
cancellation, timeout and startup-failure completion. This local workspace has no
Docker daemon; real-container acceptance remains pending that CI job and is not
claimed by the mocked tests.

## Source and private dependencies

- #94: schema 56 adds administrator-managed consumer/repository grants and
  immutable dependency resolutions. A bounded server downloader keeps the raw
  GitHub credential in stdin and repository-specific API requests. Archive
  redirects are confined to that repository on codeload and lose Authorization.
  Jobs receive a separate live dependency capability. Revocation, scope,
  restart, expiration, safe redirects and credential visibility have tests.
- #95/#97: assignment v17 supports complete ancestor history and ancestral tags
  for `fetch-depth: 0`, within retained transport/tree limits and new object/tag
  budgets. Secondary checkouts require an exact repository/ref grant, pin their
  first SHA across the run family and use a separate path. The primary checkout
  remains the captured run SHA; old snapshots retain their shallow behavior.
- #98: both REST mounts provide bounded smart-HTTP receive-pack. Trusted native
  hooks recheck live job authorization and existing protected-ref rules. Writes
  keep mirror/webhook bookkeeping without recursive workflow events. Credentials
  are URL-scoped and temporary; checkout disables credential persistence.

Validation: the broad native/HTTP run passed 316/320; all four failures were
old protocol-version assertions. The affected follow-up run passed 34/35, with
one mixed-job assertion requiring v9 for its script-only consumer; the final
file then passed 1/1. JavaScript passed 60/60. Real local HTTP pushes
passed on both mounts, including protected refs, cross-repository, read-only and
completed-token denial. Unchanged upstream checkout v6 passed full history,
prior-tag/changelog, secondary path and credential-removal checks. GitHub private
credential behavior uses equivalent controlled-download fixtures; no external
private credential was provisioned. Required check/format/interface commands and the 56-package boundary check
passed.

## Job APIs and named merge gates

- #103/#104: assignment v18 adds explicit PR-metadata and Checks-write scopes.
  Both API mounts enforce live grants and repository/editor authorization. Check
  identities bind the current job, attempt and SHA; immutable identity, ownership,
  bounded output and delivered-secret masking prevent impersonation or leakage.
- #106: a separate Actions-read REST adapter lists the selected run's artifacts
  and grants bounded, live-authorized downloads. Twirp retains its same-run scope.
  Expired artifacts, capabilities, jobs and cross-repository requests are denied.
- #111: branch settings/API accept workflow, named-job and named-check selectors.
  Current candidate/version/generation and latest producer identity are required.
  Missing and duplicate names block explicitly; optional failures do not block
  a selected successful job/check. Whole-workflow rules retain their old meaning.

Validation: the native/HTTP regression set passed 52/53 initially; the only failure
was an assertion expecting 400 instead of the Checks API's existing 422 adapter
status. The corrected API test and real upstream Artifact v4 cross-run fixture
then passed 2/2. Named gates cover moved candidates, missing/duplicate job and
check names, and optional failures. JavaScript tests passed 60/60; package
boundaries passed for 56 packages. The CI storage acceptance script also runs
that upstream cross-run fixture. No external App or cloud resources were created.

## Deferred and reporting-only work

#78, #96, #112 and #113 are deferred. #105 is a reporting-only TODO: package
publishing permissions retain their existing behavior. Live cloud configuration,
production deployment and external publication are outside this implementation.
Real ARM64/VM/container/platform acceptance must be reported separately from
fixtures; no fixture is evidence of a deployment or external publication.
