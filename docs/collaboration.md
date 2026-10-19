# Repository Collaboration

Moonhub supports issues and merge requests within one repository. It uses the
existing SQLite database and bare Git repositories. The Web and SSH processes
never execute submitted code; optional MR checks use the separately provisioned
Pipeline provider and Runner. Schema migrations are applied by Web at startup.
Upgrade both Web and SSH to the same image.

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
descriptions, comments and replies to 20,000. Content is plain text, never trusted
HTML.

An issue can be linked when creating an MR, including through the issue's
"Create merge request" link. Only issues in the same repository can be linked.
Merging does not automatically close an issue.

## Merge Requests

Contributors create MRs between existing local branches with a single common
ancestor. There is at most one open MR per source/target pair. MRs support draft,
ready, closed, reopened and merged states, versioned comparison, discussion
threads, replies, resolve/reopen state, approval, requests for changes and review
withdrawal. Authors cannot approve their own work. Only team owners/admins or
site administrators can merge.

Source and target commit IDs identify each comparison version. Refreshing an
open MR reads actual refs; changes on either side create a new version. Reviews
apply only to that version. Inactive users and former contributors do not count
toward approval. Internal refs under `refs/moonhub/` retain reviewed objects and
are hidden from SSH clients. Draft and reopen transitions clear prior approvals.

Diffs compare the merge base to the source. Mergeability is cached per version
using Git's native merge algorithm. The worker recalculates and verifies it
before merging. Resolve conflicts locally and push again. The initial release
uses two-parent merge commits and retains source branches. Required Pipeline
checks are available through opt-in branch protection, with optional automatic
`pull_request` workflows discovered from the target branch; see
[MR checks](merge-checks.md). Forks, squash/rebase and auto-merge are outside this
release.

Each comment starts a discussion; review decisions with a nonempty body also
start one, without changing review semantics. Contributors can reply to current
or historical revisions, including after an MR closes or merges. Replies remain
on the original revision. Discussion authors, MR authors and team administrators
can resolve/reopen with an independent optimistic state version. Resolve state
records its last actor/time and survives replies, source updates and comment
deletion/restoration. Resolve never clears a changes-requested review, and
unresolved discussions do not add a merge gate.

Discussion filters and the unresolved count cover all MR revisions. Resolved
threads are collapsed in the overview with a root-text preview and stable ID;
selecting a thread opens it. Deleted roots keep an explicit placeholder. Reply
drafts are isolated by discussion and revision. The Web view uses native
disclosures and separator-based threads, with replies indented one level. Reply
and resolve/reopen actions use CSRF-protected POST forms and work without
JavaScript. Overview pages show at most 50 threads and the latest three replies
per thread; thread detail pages expose every reply in chronological pages of 50.
Original comment IDs, review decisions and deletion tombstones are preserved by
migration 019, without replaying old notifications. The existing activity history
remains available as a secondary disclosure. Replies and resolve/reopen events use the
existing MR subscription and delivery authorization rules. Notification links
retain the discussion and stable comment ID; the server resolves the actual
reply page, including deleted-comment placeholders. Delete/restore actions return
to that same page and comment anchor. Migration 020 backfills existing targets
without replaying notifications or mail or resetting read state.

Inline code comments start the same discussions with an immutable anchor to a
saved MR version and comparison: All changes or one commit, base/head object IDs,
old/new file paths, side, inclusive line range and saved code context. Select
1–100 consecutive displayed lines on one side within one diff hunk, using the
path on that side. Binary files, pure renames and positions without a displayed
text diff cannot accept anchors. Source updates and force pushes never relocate
an existing anchor. Replies, resolve/reopen and comment delete/restore retain
the anchor and use the existing permissions and notification rules. Review and
merge policy is unchanged.

The Changes view shows code discussions for the exact selected version and
comparison; the Discussion overview includes discussions across all revisions
and comparisons. Notification and discussion links restore the historical
Changes version and commit selection. The code-location link highlights the
anchored range. Saved context remains readable even after source updates; each
selected code line is saved with up to 120 Unicode scalars plus an ellipsis
when truncated.

Contributors can click, Shift-click or drag diff line numbers and use Comment on
selected lines to fill the native Comment on code form. Its path, side, start
and end fields also work without JavaScript. Validation errors retain the
submitted location and body. Enhanced drafts are isolated by revision and
comparison. Repository readers can inspect discussions without a create action.
Small diffs retain their natural height; larger diffs use bounded scrolling.

Discussion list API responses contain 512-scalar body previews with an explicit
`body_truncated` flag. Inline anchors also preview at most 512 context scalars,
with `context_truncated` indicating omitted saved context. Single-discussion
reads retain complete root/reply bodies and the complete saved code snippet;
this keeps overview responses within the CLI response budget without losing
content.

Git output is bounded to 2 MiB with a 60-second operation timeout. Oversized diffs
require local inspection instead of exhausting the server. The Commits view and
Changes commit selector page through 100 commits at a time. Changes defaults to
the entire selected version (merge base to source); selecting a commit compares
it with its first parent. Merge commits explicitly identify
this first-parent comparison; parentless imported commits compare with the empty
tree. Commit links from the MR remain in its Changes view, preserving the
selected MR version and review context. A separate Commit details link opens the
repository commit page. Selecting another MR version
resets the commit selection to All changes.

The labeled native Changes selector uses a URL-backed GET form and retains a
View button without JavaScript. Long selected commit titles wrap within the
existing workspace, including on mobile.

Commit selection uses a full lowercase SHA and is validated against the saved
version's source-minus-target ancestry, including commits beyond the first page.
Commits outside that version are rejected even if they exist in the repository.
Object IDs must name commits directly; annotated tag, tree and blob IDs are not
accepted. Commit selectors and selected-commit headings use bounded previews
(2048 UTF-8 bytes for subjects and 512 for author names, plus an ellipsis when
truncated). Previews end at a complete Unicode scalar; stored Git data is unchanged.
Metadata is drained as a stream, so large subjects do not block a small diff.
Historical comparison URLs remain tied to the saved objects after branch updates
or force pushes. Reviews still apply to the entire MR version, not the selected
commit. Diffs use the existing renderer, with large files initially collapsed.

## Review Requests and Notifications

Authors and administrators can request version-bound reviews from active
contributors. Inbox combines unread updates, pending reviews and assigned Issues.
Participants may unsubscribe from ordinary updates and opt in to email. See
[notification behavior and upgrade requirements](notifications.md).

## Protection and Concurrency

Use the repository MR list's Branch protection link to protect exact branch
names. Protected branches reject all direct SSH updates, creation, force-push
and deletion, including administrator pushes. Seed a branch before protecting
it. Rules require zero or one approval from someone other than the author.
Unprotected branches require no approval, but current requests for changes still
block merging. Existing branches are not protected automatically. Protection
rule changes are recorded in `repository_audit`.

Rules can also name required workflow paths. Their checks use the pinned target
configuration and test the merged source/target tree. Every required check must
succeed for the current MR version and policy generation before merging.
Execution authorization is separate from code-review approval; ordinary
contributors cannot automatically execute new source revisions.

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
