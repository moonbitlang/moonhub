# Repository Collaboration

Moonhub supports issues and merge requests within one repository. It uses the
existing SQLite database and bare Git repositories; it does not add a service or
run submitted code. Migration 004 is applied by web at startup. Upgrade both web
and SSH to the same image.

## Modules

- `gitops/`: independent MoonBit package for bounded Git subprocesses, branch
  validation, comparisons and cross-process write locks. No database or HTTP dependency.
- `repository/repository_scope.mbt`: shared repository authorization and write coordination.
- `collaboration/merge_store.mbt`, `collaboration/issue_store.mbt`: persistence models and scoped reads.
- `collaboration/merge_requests.mbt`, `collaboration/issues.mbt`: creation, transitions, reviews and validation.
- `collaboration/merge_worker.mbt`: durable merge execution and recovery.
- `collaboration/branch_protection.mbt`: branch rules and receive-side enforcement.
- `ssh/branch_protection.mbt`: authenticated pre-receive entry point.
- `web/views/merge_requests/`, `web/views/issues/`: independent page packages containing
  authenticated HTTP/CSRF handlers, escaped rendering and HTTP regression tests.

See [package architecture](architecture.md) for dependency direction and tests.

## Issues

Repository readers can view issues. Contributors can open issues and comment.
Authors and team owners/admins can edit, assign, close and reopen issues.
Assignees must be active team members. Issue numbers are repository-local and
allocated in the creation transaction. Filters support literal title matching,
status and assignment to the current user.

Edits and state changes carry an optimistic version. Stale forms cannot overwrite
newer changes. Comments and transitions are recorded in an activity log. Lists
and discussions are paginated at 50 entries. Titles are limited to 200 characters;
descriptions and comments to 20,000. Content is plain text, never trusted HTML.

An issue can be linked when creating an MR, including through the issue's
"Create merge request" link. Only issues in the same repository can be linked.
Merging does not automatically close an issue.

## Merge Requests

Contributors create MRs between existing local branches with a single common
ancestor. There is at most one open MR per source/target pair. MRs support draft,
ready, closed, reopened and merged states, versioned comparison, discussion,
approval, requests for changes and review withdrawal. Authors cannot approve
their own work. Only team owners/admins or site administrators can merge.

Source and target commit IDs identify each comparison version. Refreshing an
open MR reads actual refs; changes on either side create a new version. Reviews
apply only to that version. Inactive users and former contributors do not count
toward approval. Internal refs under `refs/moonhub/` retain reviewed objects and
are hidden from SSH clients. Draft and reopen transitions clear prior approvals.

Diffs compare the merge base to the source. Mergeability is cached per version
using Git's native merge algorithm. The worker recalculates and verifies it
before merging. Resolve conflicts locally and push again. The initial release
uses two-parent merge commits and retains source branches. Forks, squash/rebase,
CI, inline review threads and auto-merge are outside this release.

Git output is bounded to 2 MiB with a 60-second operation timeout. Oversized diffs
require local inspection instead of exhausting the server. The commits view
displays at most 100 commits. Diffs use the existing renderer, with large files
initially collapsed.

## Protection and Concurrency

Use the repository MR list's Branch protection link to protect exact branch
names. Protected branches reject all direct SSH updates, creation, force-push
and deletion, including administrator pushes. Seed a branch before protecting
it. Rules require zero or one approval from someone other than the author.
Unprotected branches require no approval, but current requests for changes still
block merging. Existing branches are not protected automatically. Protection
rule changes are recorded in `repository_audit`.

SSH uses a deployment-owned pre-receive hook, never a repository hook. It
revalidates key, account and repository access and rejects internal-ref updates.
SSH pushes, merges and MR state changes share a per-repository filesystem lock.
Writes wait up to 15 seconds for an existing writer. This requires local shared
storage and is not a multi-host HA deployment.

For non-Docker SSH deployments, install `deploy/hooks/pre-receive` and
`deploy/hooks/reference-transaction` as executable files in a trusted directory
and supply `MOONHUB_HOOKS_PATH` and `MOONHUB_BIN` to SSH sessions.
Missing or non-executable hooks fail closed. Docker installs both automatically.

## Recovery

Before modifying Git, the job records its actor, selected version and proposed
commit. One Git ref transaction verifies the source, compares-and-swaps the
target and creates a receipt under `refs/moonhub/merges/`. SQLite is then marked
merged. On restart the receipt reconciles the job even if later pushes moved the
target. A receipt mismatch fails closed for operator inspection. Stale refs,
conflicts, deleted branches and revoked merge/review permissions fail without
advancing the target. Failed jobs can be retried after refreshing and addressing
the cause; duplicate merge submissions are rejected.

Back up the database and repositories together before upgrades. Restoring only
one side can invalidate recovery receipts and review history. No destructive
cleanup or automatic repair is applied to existing data.

## Verification

The MoonBit suite covers schema-3 migration, review invalidation, competing
merges, recovery after a later target push, branch deletion, permission revocation,
repository isolation, CSRF, escaping and stale edits. The Docker/browser smoke
test runs real SSH pushes and verifies desktop/mobile layout geometry using
disposable test volumes.

```sh
moon test --target native --strip -j 1
docker build -t moonhub:collaboration .
node scripts/collaboration-smoke.cjs
```

The browser smoke requires Playwright and its Chromium browser in the host Node
module search path. `MOONHUB_COLLABORATION_IMAGE` selects an alternate image.
Its Compose project uses unique names, dynamic loopback ports and disposable
volumes; it never connects to the prepared preview's data.

Native tests use the temporary [compiler workaround](../README.md#temporary-compiler-workaround).
