# Repository UX changes and screenshots

Repository pages now share Code / Issues / Pull requests / Actions / Settings.
These tabs preserve repository context when switching features; each feature's
page content and applicable sidebar hold its filters and actions. Code has no
feature sidebar; file pages retain their own directory navigation. MoonHub
branding, the English interface and the light theme are retained.

Screenshots come from disposable local databases and repositories, including the
Alice demo account. They contain no production data. This directory holds 36
original browser screenshots: six before/after pairs at 1440px, populated detail
pages, menus and mobile pages at 390px. Additional desktop screenshots are 1440px,
except Secrets, which uses the existing smoke test's 1280px capture. Before/after
pairs use the same repository content; supplemental screenshots use separate
demo data. The new root Release summary screenshots at 320, 390, 900 and 1440px
use the same separately published v1.4.0 fixture as the release details. The
empty-repository screenshot uses a separate unborn repository. Automated
coverage also includes 320, 390, 900 and 1440px.

## Shared navigation and code browsing

Files, Commits, Issues, Merge requests, Pipelines, Releases and repository
settings previously shared one long sidebar. Five repository tabs now stay at
the top, while the sidebar changes with the active feature. Account, team and
site destinations move into a separate global drawer. Settings is visible to
repository managers and opens the existing branch protection page by default.

Code removes the whole feature sidebar, including its workspace switcher and
collapse controls, and uses the available width. Other feature sidebars remain.
The branch/tag picker, file finder and green Code menu sit above the files.
The head commit summary places the history icon and full commit count at the
right, with **1 commit**, **52 commits** or **0 commits** as appropriate. Its title
and hash open commit details; the count keeps the selected revision in
`/commits?rev=...`. The total counts all commits reachable from the summary's
commit SHA, independently of the 50-entry history query. A TODO records future
SHA-based caching and bitmap index optimization. Empty repositories keep a
usable empty-history link without invalid commit links.
File pages keep History. A safely rendered README follows the files. File
pages add directory navigation, line anchors, path/source copying and Markdown
Preview/Code switching. Creation and import forms explicitly show Owner,
repository name and visibility while retaining task progress, retry after
failure and input recovery.

The file finder uses authorized, read-only Git queries, limited to 5,000 paths
and 2 MiB of output. Reaching the limit or encountering undecodable output shows
a notice and offers directory navigation. README previews are limited to
256 KiB. Same-named branches/tags, branches containing `/` and historical
revisions continue to use the existing revision resolution behavior.

<details>
<summary>Code: before, after and mobile</summary>

Before:

![Code before](images/repository-ux/before-code.png)

After:

![Code after](images/repository-ux/code-desktop.png)

390px:

<img src="images/repository-ux/code-mobile.png" alt="Code page at 390px" width="390">

</details>

<details>
<summary>File finder and global drawer</summary>

![File finder](images/repository-ux/file-finder-desktop.png)

![Global drawer](images/repository-ux/global-drawer-desktop.png)

</details>

<details>
<summary>Commit history and empty repository</summary>

![Commit history without a feature sidebar](images/repository-ux/commit-history-desktop.png)

<img src="images/repository-ux/code-empty-mobile.png" alt="Empty repository with a usable 0 commits link at 390px" width="390">

</details>

## Issues

The list uses title search, Open/Closed filters and compact rows. The sidebar
opens All issues or Assigned to me. Filters and pagination keep their existing
URLs, so browser back/forward navigation restores the filtering context.

Details place the description, activity and comment editor in the main column,
with Assignee, related PRs, subscriptions and Copy reference in the right rail.
Mobile pages stack these sections. Close/Reopen and Add comment remain separate
actions; copied references use `#123`.

<details>
<summary>Issues: before, after, list and discussion details</summary>

![Issues before](images/repository-ux/before-issues.png)

![Issues after](images/repository-ux/issues-overview-desktop.png)

![Populated issue list](images/repository-ux/issue-list-desktop.png)

![Issue discussion details](images/repository-ux/issue-detail-desktop.png)

<img src="images/repository-ux/issue-detail-mobile.png" alt="Issue discussion at 390px" width="390">

</details>

## Pull requests

User-facing terminology becomes Pull requests. Routes remain `/merge-requests`
and references remain `!123`. The creation page orders branches as base ← compare,
clarifies the target and source branches, and offers regular or draft creation.

Details use Conversation / Commits / Files changed. Reviewers sit in the right
rail; check results and the merge action appear below the Conversation content,
so readers can assess merge readiness after the discussion. Files changed puts
Review changes before the diff and keeps file navigation, collapse controls and
Unified/Split views. MoonDiff retains its existing Token/AST and filter defaults,
shows the current mode/filter state explicitly and offers Line mode. Inline
comments still publish immediately; validation and reviews retain their existing
version rules.

<details>
<summary>Pull requests: before, after and creation</summary>

![Pull requests before](images/repository-ux/before-pull-requests.png)

![Pull requests after](images/repository-ux/pull-requests-overview-desktop.png)

![Base/compare branches and draft creation](images/repository-ux/pull-request-create-desktop.png)

</details>

<details>
<summary>Conversation and Files changed: desktop and mobile</summary>

![Conversation and merge status](images/repository-ux/pull-request-conversation-desktop.png)

![Files changed and Review changes](images/repository-ux/pull-request-files-desktop.png)

<img src="images/repository-ux/pull-request-files-mobile.png" alt="Files changed at 390px" width="390">

</details>

## Actions

The Pipelines UI is renamed Actions; routes remain `/pipelines`. The sidebar
shows workflows in the current result and Trigger events. Status, branch and
workflow filters expose the existing capabilities. Run details remain organized
by jobs, steps and logs. Manual execution is grouped on Run workflow, which
distinguishes rerunning a saved snapshot from running the latest branch revision
so the revision being executed is clear.

<details>
<summary>Actions: before, after, workflows, manual runs and logs</summary>

![Actions before](images/repository-ux/before-actions.png)

![Actions after](images/repository-ux/actions-overview-desktop.png)

![Workflow list](images/repository-ux/actions-workflows-desktop.png)

![Run workflow](images/repository-ux/actions-run-workflow-desktop.png)

![Jobs, steps and logs](images/repository-ux/actions-log-desktop.png)

</details>

## Releases

Only the root Code page shows a Releases summary, including after changing the
branch. The summary uses the existing `Service.latest` selection policy and
shows the title, version, Latest badge, publication time and View all releases.
Its 296px right rail has a 32px gap; at 900px and below it follows the README.
When there are no stable releases, including draft-only or prerelease-only
repositories, it shows “No stable releases published.” and keeps the list link.
Child directories, files, commits and release pages omit the summary. Release
list/detail pages retain their feature sidebar. Release
cards group the version, commit, time, status and safe Markdown notes. Details
organize downloads into a native collapsible Assets list. The v1.4.0 screenshot
uses the existing draft → CLI/API upload → publish flow and includes a real
79-byte CHANGELOG.txt asset. The browser adds no access-token input; published
release and asset immutability remains unchanged.

<details>
<summary>Releases: before, after, cards and assets</summary>

![Releases before](images/repository-ux/before-releases.png)

![Releases after](images/repository-ux/releases-overview-desktop.png)

![Release cards](images/repository-ux/release-list-desktop.png)

![Release details and a real asset](images/repository-ux/release-detail-desktop.png)

</details>

<details>
<summary>Root Release summary: desktop, 900px, 390px and 320px</summary>

These supplemental screenshots use separately published demo data; the original
Code before/after pair above keeps the same repository content and no releases.

![Root Code page with latest stable release at 1440px](images/repository-ux/code-release-desktop.png)

![Release summary below the README at 900px](images/repository-ux/code-release-900.png)

<img src="images/repository-ux/code-release-mobile.png" alt="Root Release summary at 390px" width="390">

<img src="images/repository-ux/code-release-320.png" alt="Root Release summary at 320px" width="320">

</details>

## Settings

The Settings sidebar groups branch protection, Actions configuration,
Secrets/Variables, Webhooks, Deploy keys and Mirrors. Secrets/Variables use
adjacent tabs. Ordinary members can still access read-only Variables under
Actions. Existing forms, errors, version conflict feedback and permissions are
preserved. Removing branch protection requires opening a native confirmation
section to reduce accidental submissions.

<details>
<summary>Settings: before, after, Secrets/Variables and deletion confirmation</summary>

![Settings before](images/repository-ux/before-settings.png)

![Settings after](images/repository-ux/settings-overview-desktop.png)

![Secrets](images/repository-ux/settings-secrets-desktop.png)

![Variables](images/repository-ux/settings-variables-desktop.png)

![Branch protection deletion confirmation](images/repository-ux/settings-branch-confirmation-desktop.png)

</details>

## Keyboard behavior, fallbacks and scope

- `/` focuses the visible page search, `t` opens the Code file finder, and Esc
  closes menus and restores focus. Inputs, editors and editable content do not
  trigger these navigation shortcuts.
- Menus and download lists use native details; links and forms retain their
  no-JavaScript fallback. Page transitions still dispose listeners, editors,
  polling and unfinished requests. Enhancement stays active when Code omits the
  sidebar; SPA back/forward restores the saved feature-sidebar collapse preference.
- Draft recovery, navigation/duplicate-submit protection during uploads, retained
  inputs after upload failure and retry are preserved.
- Search maps only to existing capabilities. PR Open/Merged/Closed remain
  separate filters, and counts are omitted when no real totals exist.
- `!123` / `#123`, MoonDiff defaults, immediate inline comments and merge
  permissions are preserved. Labels, Milestones, Projects, Star/Fork, online
  editing, Blame, ZIP, HTTPS clone and browser-reencoded raw downloads are not
  added.
- Rabbita SSR/SPA, the React code view and EasyMDE are retained. Changes are
  limited to Web presentation, read-only Git data composition, browser assets,
  tests and documentation. Business packages, the database, APIs, permissions
  and background tasks are unchanged.
- Generated interface changes are limited to optional sidebar content, optional
  code-toolbar content and the shared Secrets/Variables tab renderer in
  `web/ui`. Business package interfaces are unchanged. This layout revision
  adds no public interfaces or shared layout parameters.

## Validation results and limitations

The commit-count update passed 40 repository page tests and five focused browser
tests covering branch/tag selection, empty repositories, responsive layouts and
native navigation. The HTTP regression includes 52 reachable commits to verify
totals beyond the 50-entry history limit. Nine Code screenshots were refreshed.
The table below records the earlier full UX acceptance run.

| Check | Result |
| --- | --- |
| Browser asset build and TypeScript | Passed |
| check → fmt → info and pre-commit before every commit | Passed |
| Native build with `--strip -j 1` | Passed |
| Full MoonBit suite | 815/815 |
| Full Playwright suite | 95/95 |
| Repository UX and upload regressions | 15/15 (included in Playwright) |
| Branch/tag/file-index limits | Passed with more than 5,000 branches and 5,002 paths |
| Package boundaries | 50 packages passed |
| Existing collaboration UI / Secrets / UI browser smoke | Passed; 37 UI smoke screenshots |
| Loading/fallback smoke | Passed: 20 delayed-script navigations plus no-script/failed-script fallback |

Acceptance used Git 2.43.7, which supports `merge-tree --write-tree`; system Git
2.34.1 does not meet that requirement. Local build and test logs are retained in
`_build/repository-ux/layout-update/` for this revision. Reproduction commands are in the
[coverage checklist](repository-ux.md#verification-and-screenshots).

Two limitations from the earlier acceptance remain recorded separately; these
smokes were not rerun for this layout revision and are not counted as passed:

1. The earlier live-log smoke's final flushed-tail assertion failed identically
   on this branch and pristine master. Earlier log updates, job/step navigation, search,
   wrapping, follow and hidden-tab checks complete. This change does not modify
   polling or Pipeline business code.
2. The earlier runner merge-check smoke could not complete because the host
   lacked the fixed Node/action-runtime paths, producing exit 127. Supplying
   those paths in a private namespace then returned EACCES for the native server. Host
   runtime directories and runner policy were not changed. MoonBit merge/review/
   check HTTP regressions pass.
