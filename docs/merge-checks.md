# Merge Request Pipeline Checks

Same-repository merge requests automatically discover target-owned
`pull_request` workflows for opening, source updates and reopening. Discovery is
independent of branch protection and **Run push workflows**. These checks are
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
`on: pull_request` in the target workflow. `types` can select any nonempty subset
of `opened`, `synchronize`, `reopened`; omitted means all three. Other types and
branch/path filters are rejected. Draft MRs wait until ready. Source changes
select `synchronize`; reopening selects `reopened`. Advancing only the target
reruns selected workflows against a new merged tree while retaining the last
source/lifecycle event. At most 64 target workflow entries are inspected.
Definitions introduced only in the source branch are not discovered until they
reach the target. Invalid definitions appear as preparation errors.

An empty required-workflow list preserves approval-only protection. Existing
rules gain no required checks automatically. Missing, invalid, or conflicting
required workflows block merging; optional failures do not. They are never
treated as successful or silently skipped.
Provider availability and label/scope blockers are explained on the run page.

## What Is Checked

Every check belongs to one MR comparison version, whose source and target commit
IDs are pinned in `merge_revision`. The worker reads the workflow from that
**target commit**, then creates a pinned two-parent candidate commit with Git's
merged tree. The existing Runner downloads and tests that candidate. Deleting
or weakening the workflow in the source branch cannot replace the executed
workflow definition. Scripts invoked by that workflow remain proposed repository
code; target-owned YAML does not make untrusted code safe.

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
a check permits the proposed code to run with the provider's existing isolation
and network policy; inspect the change before approving it.

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

Migration 017 adds the MR event, distinguishes automatic/required checks and
preserves existing execution approvals. Existing run definitions without `uses`
remain readable and runnable. New checkout assignments require matching provider
and Runner images; see [assignment compatibility](pipelines.md#runner-protocol-step-2).

Migration 014 preserves existing MRs, reviews, branch rules, and Pipeline runs.
It adds opt-in requirements, versioned check state, and immutable run-to-check
links. The latest linked run updates check status transactionally in SQLite.
Upgrade Web and SSH together because trusted push hooks consult the new policy.
Back up the database and repositories together before upgrading; an older binary
cannot open the upgraded schema. Rollback requires the matching backup, not
just an older executable.

```sh
moon check --deny-warn
moon fmt
moon info
moon test --strip -j 1 --deny-warn
node scripts/check-package-boundaries.cjs
npm run build --prefix js
moon build --strip -j 1 --deny-warn
node scripts/merge-checks-smoke.cjs
```

The smoke requires Node with `node:sqlite`, Playwright/Chromium, Git, and a C
compiler. It creates an isolated local database/repository and binds only to
loopback. A real Runner executes only the script's trusted fixture using
`--unsafe-local`; this is not a container-isolation acceptance test and must not
be used with user workloads. It verifies merged-tree execution, target-owned
configuration, restart deduplication, failed/stale results, reruns, gated merge,
and desktop/mobile navigation. It cleans up its server and data; screenshots
and a receipt remain under `_build/merge-checks-smoke/`. No production service
is touched.
