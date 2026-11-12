# Merge Request Pipeline Checks

Same-repository merge requests automatically discover `pull_request` workflows
from their pinned candidate merged commit for opening, source updates and
reopening. Discovery is independent of branch protection and **Run push workflows**.
These checks are
optional for merging unless their paths are required by branch protection.
Existing required `workflow_dispatch` or `push` workflows continue to run
independently of their trigger filters. No new provider credential is needed.

## Enable

1. Provision a Pipeline provider with access to the repository and labels matching
   the workflow. See [Pipelines](pipelines.md).
2. Commit a supported workflow under `.github/workflows/` on the target branch.
   Existing `workflow_dispatch` or `push` workflows can be used unchanged. The
   branch rule requests MR checks independently of those trigger filters; the
   workflow must still pass the existing bounded parser.
3. Open **Branch protection**, add or edit the exact target branch, and enter
   required workflow paths, one per line. Up to 16 unique paths are supported.
   For example: `.github/workflows/build.yml`. Save the rule.
4. Create an MR or mark an existing draft ready. **Pipeline checks** on the MR
   shows preparation, approval, execution, and terminal states with links to the
   run and its step logs. **Refresh checks** reloads the current comparison and
   results without periodically replacing a review form.

For optional automatic CI, only steps 1, 2 and 4 are needed: declare
`on: pull_request` in the candidate workflow. `types` can select any nonempty
subset of `opened`, `synchronize`, `reopened`; omitted means all three. Other types
and
branch/path filters are rejected. Draft MRs wait until ready. Source changes
select `synchronize`; reopening selects `reopened`. Advancing only the target
reruns selected workflows against a new merged tree while retaining the last
source/lifecycle event. Changing an open MR's target branch follows the same
selection semantics: it retains the most recently observed source/lifecycle
event (or selects `synchronize` if the source also changed), creates a new
comparison even for identical target commits, and starts a new check generation.
Old execution approvals tied to the prior generation are not reused; current
manager-push authorization of the exact source still follows the normal policy.
Old runs are canceled asynchronously and their results cannot satisfy the new
version. Required paths are always selected from the new target's rules, and
`github.base_ref` in new runs names the new target. Historical runs keep their
saved context. At most 64 candidate workflow entries are inspected.
A workflow added by the source is discovered immediately when its candidate
trigger matches. Deleting an optional workflow, or removing its matching trigger,
omits it from the new comparison. Target-branch required paths are always
selected regardless of candidate triggers; deleting a required workflow produces
a blocking preparation error. Invalid or oversized definitions appear as per-file
preparation errors without preventing other workflows, including required
checks, from being scheduled. Reopening observes the source before the browser
or API request returns; later pushes select `synchronize` even when workflow
discovery has not run yet.

An empty required-workflow list preserves approval-only protection. Existing
rules gain no required checks automatically. Missing, invalid, or conflicting
required workflows block merging; optional failures do not. They are never
treated as successful or silently skipped.
Provider availability and label/scope blockers are explained on the run page.

## What Is Checked

Every check belongs to one MR comparison version, whose source and target commit
IDs are pinned in `merge_revision`. Under the repository write lock, the worker
first verifies the merged tree and pins one two-parent candidate commit per
comparison version. Conflicted comparisons cannot produce a run. Workflow
discovery, saved YAML, the normalized plan, checkout, context and step logs all
use that exact candidate. No moving branch tip is reread to select workflow
content during execution. Source workflow edits, including shell commands and
setup actions, are therefore tested before merging together with simultaneous
target changes. Invalid proposed YAML fails preparation on its own MR.

Required paths remain controlled by the target branch's saved protection policy,
not by candidate YAML. Candidate changes can alter a required workflow's steps;
a missing or deleted required file remains a blocking error. Review proposed
workflow changes as executable code before authorizing checks.

MR checks capture `github.event_name = pull_request`, both branch names and
the candidate commit SHA at creation. Supported `env` references are resolved
against that snapshot, never current refs. Reruns retain the saved context and
env values; see [run context](pipelines.md#run-context-and-environment-references).

The candidate commit hash is distinct from the eventual merge commit hash.
Their tree contents must match for the checked comparison; the merge worker
rechecks both refs and the merge tree before its atomic Git ref transaction.
Changing either branch creates a new version that needs new successful checks.
Old results remain visible on their historical version but cannot authorize
the new version.

## Execution Permission

The existing manager-only execution policy remains in effect:

- A repository owner/admin or site administrator creating a ready MR, marking
  it ready, or reopening it authorizes execution of that comparison.
- A durable, recovered manager push of the exact source commit also authorizes
  its checks. Recording these events is enabled when the repository has required
  checks or open MRs, independently of the **Run push workflows** setting.
- A contributor's new source revision without such authorization waits for a
  manager to use **Approve and run checks**. Read access or opening the page
  does not grant execution authority. Execution approval is not a code-review
  approval and does not count toward required reviews.
- When only the target advances, execution permission for an identical source
  may carry forward within the same ready/reopen and policy generation, provided
  its authorizing manager still has access. Check results never carry forward.
- Account and repository permissions are rechecked when publishing a run and
  throughout the existing claim/lease protocol. Providers remain explicitly
  scoped, and job containers receive no provider credential.

Execution approval is durably bound to the source SHA and policy generation
before asynchronous discovery, even when no checks exist yet. A CLI/API MR
created using a collaboration write token does not create such approval.
Use an execute token's `approve-checks` operation or an authorized browser action.

Forks and arbitrary external-contributor execution are not enabled. Approving
a check permits both proposed YAML and repository code to run with the
provider's existing isolation and network policy. This includes added commands,
setup actions and changed trigger definitions; inspect these changes before
approving. A new source commit needs fresh execution authorization even when
only its workflow changes. A target-only advance can retain approval for the
same source, but always creates a fresh candidate and fresh check results.

## Lifecycle and Recovery

The Web process polls eligible MRs with a persisted five-second per-MR cursor.
It refreshes refs, prepares checks, and cancels superseded runs under the shared
repository write lock. New versions, draft/closed state, and changed required
workflow lists invalidate old work. Claims and live attempts also verify the
current MR version/generation and requirement, so known obsolete work cannot
be newly claimed while waiting for cleanup. Running processes stop through the
existing cancellation/lease protocol, not an unbounded synchronous wait.

Check creation and run linking are transactional and keyed by MR, version,
generation, and workflow path. Restarting the worker does not enqueue another
copy of a published check. A crash before publication can leave an orphan Git
pin, which is safe to retain; checks and pins have no new automatic retention
policy in this release.

Use **Approve and run checks** to retry preparation errors. Use **Rerun snapshot**
on a completed run to retry execution. A rerun retains the immutable candidate
and workflow and becomes the check's authoritative run; an earlier success
cannot override its result. Only the latest check of a current open, ready MR
can be rerun, and reruns are rejected while merging.

All required checks must succeed alongside the existing review/conflict policy.
The gate is checked both on merge submission and by the merge worker immediately
before updating Git. Failed, cancelled, lost, timed-out, missing, pending, or
approval-waiting checks block the merge. Changing the required workflow set or
closing/reopening or marking draft/ready starts a new generation.

## Upgrade and Verification

Candidate-workflow selection needs no database migration and does not rewrite
saved runs. Previously published target-workflow runs retain their original YAML,
plan and candidate on snapshot rerun. New comparisons use candidate definitions.
Use compatible Web/provider/Runner versions when proposing new actions: a newer
parser or setup action must actually execute on the MR's candidate, rather than
only compile its implementation under the old workflow.

The baseline schema stores the MR event, automatic/required checks and execution
approvals. Existing run definitions without `uses` remain readable and runnable.
New checkout assignments require matching provider and Runner images; see
[assignment compatibility](pipelines.md#runner-protocol).

The baseline schema includes MRs, reviews, branch rules, Pipeline runs, opt-in
requirements, versioned check state, and immutable run-to-check links. The
latest linked run updates check status transactionally in SQLite. Upgrade Web
and SSH together because trusted push hooks consult the new policy. Back up the
database and repositories together before upgrading; an older binary cannot open
the upgraded schema. Rollback requires the matching backup, not just an older
executable. See [database compatibility](../db/README.md).

```sh
moon check --deny-warn
moon fmt
moon info
moon test --strip -j 1 --deny-warn
node scripts/check-package-boundaries.cjs
npm run build --prefix js
moon build --strip -j 1 --deny-warn
node scripts/merge-checks-smoke.cjs
MOONHUB_SMOKE_MOONBIT_VERSION=nightly node scripts/merge-checks-smoke.cjs
```

The smoke requires Node with `node:sqlite`, Playwright/Chromium, Git, and a C
compiler. It creates an isolated local database/repository and binds only to
loopback. A real Runner executes only the script's trusted fixture using
`--unsafe-local`; this is not a container-isolation acceptance test and must not
be used with user workloads. It verifies merged-tree workflow selection,
proposed shell commands and their persisted step logs, restart deduplication,
failed/stale results, reruns, gated merge, and desktop/mobile navigation. It
cleans up its server and data; screenshots, a receipt and per-run plans, context
and step logs remain under `_build/merge-checks-smoke/`. No production service
is touched. The optional `MOONHUB_SMOKE_MOONBIT_VERSION` run reproduces the !28
setup change on a real local Web/Runner pair: the target has no setup action,
the candidate adds `moonhub/setup-moonbit@v1`, and the run must persist and log
the requested version, execute setup successfully and select the installed
job-local toolchain in the next step. It requires outbound HTTPS to the official
MoonBit installer/toolchain endpoints; allow several minutes for installation.
