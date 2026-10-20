# Collaboration UI improvement brief

Status: approved brief implemented on `codex/collaboration-ui`; local acceptance
evidence is recorded below. Production deployment is a separate step.
Date: 2026-10-13, Asia/Shanghai.

## Scope and intent

The user selected both MR review and Pipeline troubleshooting, including Issue
and Inbox lists. Desktop is the primary work environment; mobile supports status
checks and short actions. This is an Operate surface: users should quickly see
the current state, understand what blocks progress, and perform the next action.

Retain the restrained GitLab-inspired workspace, existing navigation, system
fonts, semantic colors, server-rendered forms, CSRF/permissions/version checks,
and existing React diff viewer. Reorganize the content around the task. No new
approval bypass, fabricated counts, failure diagnosis, or unsupported actions.

## Inspection evidence

Inspected the live authenticated site and source at commit `54dbb5e`:

- MR !5 Discussion and Changes, plus the populated merged MR list.
- Pipeline list and failed Pipeline #8, including expanded logs.
- Issue list in its actual empty state. Populated Issue rows need fixture-based
  verification during implementation; this review does not infer their appearance.
- Inbox with five real unread events for MR !5.
- Desktop 1440×1000 and mobile 390×844. Temporary viewport override was reset,
  and the separate inspection tab was closed. No forms were submitted.

Evidence screenshots are under `_build/ui-audit/`. This is a source/browser-based
planning pass, not a formal scored accessibility or performance audit. No visual
detector, page mutation, production changes, or independent agent assessments
were used.

## Main findings

| Priority | Observed problem | Consequence | Proposed change |
| --- | --- | --- | --- |
| P1 | Pipeline history, an execution-setting form and raw push diagnostics share one long page | Three different tasks compete; configuration and diagnostics are difficult to find | Stable repository-level Pipeline navigation tabs: Runs / Trigger events / Settings, with Runs the default |
| P1 | Run workflow pre-fills `pipeline` and `.github/workflows/build.yml`, regardless of this repository | The interface asks users to remember paths and correct misleading defaults | Select a real branch and eligible workflow from that branch; derive defaults from actual repository data |
| P1 | New MR currently selects `codex/backup-efficiency` for both source and target | A fresh form starts in an invalid comparison state | Resolve a real default target; explicitly select a different source; show comparison availability before creation |
| P1 | MR details put versions, hashes, subscription and reviewers before the description; review/checks/merge follow the entire discussion | Key state and action depend on document length | Compact MR header; visible status/next-action summary; description and discussion in main column; contextual reviewer metadata in the side column |
| P1 | Authors see only Comment, with no explanation at the review control | An unavailable approval looks like missing/broken UI; the user just encountered this | Explain author/non-author permissions where review actions appear, with a contextual request-review action when permitted |
| P1 | Failed Pipeline #8 shows Failure three times, hides logs, and opens logs at initialization/dependency output | Failure diagnosis requires several manual steps and scrolling | Select the first failed job/step, open its logs, and provide error navigation; show an excerpt only when grounded in actual output |
| P1 | Successful runs coexist with repeated red `on.pull_request is not supported` messages in push history | A workflow-configuration diagnostic can be mistaken for the result of the entire pipeline | Show event processing, per-workflow trigger outcomes and run execution results as different states, linked to their actual workflow/run |
| P1 | Inbox has five rows for the same MR, including execution-approval notices after the MR is merged | Historical events look like outstanding work | Separate actionable tasks from event history, show current resource status, then group events by resource with expandable history |
| P2 | MR/Pipeline list rows omit information needed to choose the next item | Repeated navigation between list and detail | Consistent compact rows with identity, state, branch/MR context, relevant review/CI summary and time; server-side filters where needed |
| P2 | MR description/comments render as pre-wrapped plain text | Headings, lists, code and long review reports are difficult to scan | Safe Markdown for existing content, with code blocks, links and structured typography; no arbitrary HTML |
| P2 | Repo title/Clone header occupies prominent space on MR and Issue pages, but is absent on Pipeline pages | Inconsistent location hierarchy and excessive header height | One consistent compact repository context; page-specific title and primary action; Clone becomes a secondary repository action |
| P2 | Phone layout stacks all desktop metadata before useful content; diff/log needs different behavior | Small-screen viewing requires excessive scrolling and wrapping | Status summary first, compact/collapsible metadata, unified diff, full-width log view, accessible action targets |

On the measured desktop MR !5 Discussion page, the review form starts at about
2377px, CI checks at 2731px, and merge status at 2929px. The page is about 3088px
high. These figures describe this actual long-content example, not all MRs.
On Changes, the first diff starts around 542px and the six-file diff spans about
11223px; there is no persistent changed-file navigation.

The diff initially appeared empty while its client view initialized, and then
rendered normally without browser errors. Treat this as a loading/fallback
presentation concern, not evidence that diff rendering is broken.

The second read-only inspection included the Pipeline list footer, Run workflow,
New MR, Pipeline #16 and the historical MR !5 v1 view. The create/run forms were
inspected without submission. The v1 view correctly shows an older-version
warning and Run #15, while v2 uses Run #16; preserve this working association.

## Navigation and grouping rules

Navigation hierarchy must be explicit:

1. Workspace/repository sidebar: which scope and feature am I in?
2. Page navigation tabs: which part of that feature am I using?
3. Filters: which subset of the same records am I viewing?
4. Local selection: which job, step, file or historical revision am I examining?
5. Actions: what am I doing to the selected object?

Do not style these five jobs as interchangeable controls. A tab switches a
stable content view; a filter narrows a list; a button performs an action.
Keep information together when a user needs to reference it simultaneously.

| Surface | Page tabs / grouping | Always available context | What does not become a tab |
| --- | --- | --- | --- |
| Pipeline overview | **Runs / Trigger events / Settings**; default Runs | Repository/title and contextual navigation | Run status and branch are filters, Run workflow is an action |
| Pipeline run | Job/step navigation beside its logs; expand secondary run metadata | Run identity/state, branch, selected attempt, MR/version and allowed actions | Job selection and logs are coupled; do not put them behind mutually exclusive tabs |
| MR detail | Discussion / Changes / Commits | Title/state, selected revision and compact review/check/merge-readiness summary | Approve/Merge are actions; reviewers and checks should not hide the current blocker |
| Issue list | Open / Closed views, plus title and assignment filters | Repository/page identity and New issue | Author, assignee and query are filters, not additional tab layers |
| Inbox | Current tasks and historical updates clearly distinguished; retain a useful unread view | Current resource state and explicit read state | Email preference is settings, not another task row or a large form below the queue |

Pipeline tabs are navigation links to server-rendered routes/query views, with
real URLs, `aria-current`, browser back/forward and no-JavaScript support. Load
only the selected view's data. Do not render all histories and settings then hide
them with CSS. Settings access remains manager-only. Provider administration is
site-scoped; repository tabs must not imply control over global provider access.

These differ from client-side in-page tabs such as editor Write/Preview. Use
`tablist` / `tab` / `tabpanel` and the associated keyboard model only for a real
in-page tab widget. Page-navigation links keep ordinary link keyboard behavior.

Do not add a second tab bar to a Pipeline detail merely to house a few metadata
fields. Secondary details are expandable. If a future separate view has enough
content and a distinct task, it can earn a tab then.

## Interaction rules and task checks

The review applies the following to each flow, not just to screenshot styling:

| Rule | Moonhub implementation consequence | Acceptance scenario |
| --- | --- | --- |
| Visible, accurate system state | Text/icon state; distinguish queue, execution and conclusion; actual exit code only when available/final | A running step never implies success by showing its default `exit 0` |
| Recognition over recall | Real branch/workflow choices, labeled version history, visible failed step and changed-file list | A user can start a valid run or find a file without remembering its exact path |
| Error prevention | Prevent equal MR branches, show no-diff/unavailable-workflow state and preserve input on validation | A newly opened form has useful defaults or an explicit choice, not an invalid hidden default |
| Context continuity | URL-backed tab/filter/page/job/version state; return to the filtered list; protect unsent text | Browser back returns to the same list context; switching MR views cannot silently discard a draft |
| Meaningful action hierarchy | One dominant action per task region; ordinary secondary controls; explicit dangerous actions and permission reasons | Author understands why Approve is absent and how to request another member's review |
| Progressive disclosure | Common work first; hashes, protocol/config diagnostics, subscriptions and settings are secondary | Failure output and current merge blocker are discoverable without opening an advanced section |
| Recovery and feedback | Loading/empty/no-results/error/disconnected/stale states have distinct next steps | A stream interruption says updates are paused/retrying, rather than leaving a silently stale status |
| Accessible, stable interaction | Semantic headings, visible focus, names for icons, text alongside color, restrained live announcements | Keyboard/screen-reader flow works; live logs do not steal focus or continuously announce every line |

Tab selection uses both a clear underline and stronger text. Filters show their
active values and a reset control. A record's status stays close to its identity;
avoid placing every small badge at the far right of a wide empty row.
Use relative times for scanning, with an accessible exact time and clear zone.
Display a short linked/copied SHA with the complete value available on demand.

Mobile adaptation is structural: no multi-row wrapping tab bar that reads like
two unrelated groups; use a visible selected view and a usable compact navigation
pattern. Task navigation moves above the log, and code defaults to unified mode.
Keep primary actions reachable without covering content or the on-screen keyboard.

## Proposed MR composition

Desktop Discussion:

1. Compact header: MR number/title/state, author, source → target, current version.
2. Stable tabs: Discussion, Changes, Commits, with real counts when available.
3. Main column: safe rendered description, discussion, bounded comment composer.
4. Side column: review requests/decisions, CI checks, conflicts/protection blockers,
   and the next permitted action. Combine these into a concise merge-readiness
   summary; do not scatter duplicate status sections down the page.

The summary should answer: which revision is current, have checks passed, whose
approval is missing, and what can this user do now. Keep raw SHAs and version
history available through compact secondary controls. Reviewer requests and
subscription settings belong beside the conversation rather than before it.

Replace the current numeric Version input, View button and separate Latest link
with a native version dropdown. List real available revisions newest first,
label the newest `v2 — Latest` (using the actual version number), and clearly
identify historical selections. Include revision time when available. With
JavaScript, selecting a version navigates directly while preserving the current
Discussion/Changes/Commits tab and updating the URL; protect unsent drafts before
navigation. Without JavaScript, retain a small View submit button as the fallback.
Keep the older-version notice and existing version-bound action restrictions.

Open/merged/closed, draft/ready, old/current revision, contributor/manager/author,
conflict, awaiting execution approval, queued/running/failed CI, outdated reviews,
and pending/failed merge must each provide specific text and correct actions.
For example: "You authored this MR. Another member must approve it." Do not
replace authorization with a visually enabled button.

Desktop Changes:

- Reduce repeated metadata above the code; keep title/version and review context.
- Add collapsible file navigation with filename, additions/deletions, and jump
  targets. Preserve existing file folding and sticky file headers.
- Expose split/unified and wrap controls rather than hard-wiring a single mode.
- Keep review submission reachable from Changes, retaining the selected version.
- Reserve a loading region or retain the plain patch fallback until the enhanced
  view is ready. Do not show a misleading empty separator in place of the diff.
- Inline review threads and resolve controls are a separate feature requiring
  persistent discussion data; they are not part of the first layout change.

At narrower widths, move the summary before the content and collapse metadata.
Phone diff defaults to unified. Do not automatically overwrite the user's stored
global-sidebar preference to gain code width.

## Proposed Pipeline composition

Overview, using the three navigation tabs:

- **Runs:** aligned run list, status/branch/workflow filters, pagination and Run
  workflow. This is the default landing view for routine use.
- **Trigger events:** event reference/time/processing state, actual workflow
  outcome and generated run link, or a precise no-run reason. Unsupported workflow
  syntax must not imply that other workflows or a successful run have failed.
- **Settings:** repository automatic-trigger preference, explanation of its scope,
  explicit save feedback. Global Provider controls remain in administration.

The detail screen should behave as a troubleshooting workspace:

- Top: pipeline number/name/state, branch, linked short SHA, MR/version context,
  relevant time, and permitted rerun/cancel actions.
- Job/step navigation: select a job and then a step; surface the first failed step
  on a completed failed run and the active step on a running run. Preserve a
  user's manual selection during updates.
- Main log panel: real step output, search with next/previous match, line numbers,
  copy/download, wrap toggle, explicit follow mode and jump-to-end.
- Failure summary: failed job/step and actual exit code. Error excerpts or jump
  targets must come from the logs; do not guess the cause from "Failure".
- Queue summary: show existing provider/labels/dependency reasons prominently,
  with navigation to an existing relevant setting only for authorized users.
- Rerun copy must explain that it executes the saved snapshot. Starting a run on
  the newest branch revision is a distinct action.

Manual execution is a real selection flow: choose a repository branch, then an
eligible `workflow_dispatch` workflow from that revision. Show which revision
will be executed and why a workflow is unavailable. Fetching/validation states
must preserve the selected branch and explain stale/deleted refs. Advanced
manual path entry can remain as an explicit fallback rather than the only path.

The existing poller already retries transient failures and preserves log scroll
unless the reader is following the end. Keep those behaviors. Replace the fixed
420px nested log area with a workspace appropriate to the available viewport;
on phones, prefer a single-column selected-job log screen.

The current self-check workflow wraps many stages in one CI step. The UI can
select that failed step and navigate actual error output, but cannot invent
separate recorded steps for every self-check stage. Structured stage reporting
would be a later workflow/protocol enhancement.

Pipeline list: compact aligned rows for status, run number/workflow, branch/MR,
commit and time. Add status/branch/workflow filters and usable pagination. The
Trigger events tab is the deliberate route for "why did no run start?".

## Issue and Inbox composition

Issue list:

- Share compact page headings, filter controls, tabs and row states with MR lists.
- Existing title search and Assigned to me are useful; use a clear active-filter
  summary and reset action.
- Separate "No issues yet" from "No results for these filters". The current
  repository has no matching open Issues and displays only that generic sentence.
- Row content should emphasize title/status/assignee and recent activity. Counts,
  labels, milestones or saved views require real backing data before appearing.
- Issue detail should reuse safe Markdown and discussion patterns. It does not
  need MR-specific checks or approval panels.

Inbox:

- Make "Needs my review", "Assigned to me" and "Updates" distinct tasks/views.
- Show current MR/Issue state alongside historical event labels. A merged MR's
  old execution-approval notice must not imply approval is still required.
- Group repeated events by repository/resource, preserving expandable per-event
  actor, version and time. Perform grouping before pagination for stable results.
- Keep viewing versus marking read explicit. One row should not need a repeated
  large "Read and open" button for every historical event. A compact mark-read
  action without navigation needs its own supported server behavior.
- Move email notification preferences to notification settings, with a small
  entry point from Inbox. The work queue should focus on pending work.

## Data and implementation implications

| Change | Implementation scope |
| --- | --- |
| Compact headers, MR columns, action grouping, permission explanations, shared status language | Mainly server-rendered view composition and shared CSS/UI helpers; preserve existing services/forms |
| Safe Markdown | Shared presentation renderer with escaping/safe URL policy; existing stored text remains unchanged |
| Diff navigation/loading/mode controls | Existing `@pierre/diffs` React wrapper; derive real file information from the patch |
| Step selection, log search/follow/copy | Browser interaction and existing job/log data; preserve stream/attempt identity |
| MR/Pipeline list review/check summaries and filters | Batch business queries/DTOs; avoid one query per displayed row |
| Durations, trigger type, rerun attempts in list/detail | Expose actual attempt timestamps and trigger/MR context; current Run/JobRun DTOs do not provide all this information |
| Resource-grouped Inbox with current task state | Business/API projection plus rendering; grouping only the visible page is insufficient |
| Line review threads, labels/milestones, stage-level CI reporting | Separate capabilities; defer from the initial UI delivery |

Relevant implementation owners:

- MR: `web/views/merge_requests/merge_views.mbt` and `merge_routes.mbt`.
- Pipeline: `web/views/pipelines/pipeline_views.mbt`, `pipeline_updates.mbt`,
  and `js/src/pipeline-logs.ts`.
- Issue: `web/views/issues/issue_views.mbt`.
- Inbox: `web/views/notifications/views.mbt`, its routes, and collaboration
  notification queries.
- Shared presentation: `web/ui`, `js/src/app.css`, `js/src/custom-elements.tsx`.

Business packages must not import Web packages. New app-scoped dependencies enter
through `web/dependencies.mbt`. Preserve no-JS paths, accessible labels/focus,
status text, existing URLs, visibility rules and submitted version/CSRF fields.

## Delivery order and acceptance

1. Establish the navigation hierarchy: Pipeline Runs/Trigger events/Settings,
   consistent headings/context, action hierarchy and valid create/run defaults.
2. MR/Pipeline detail flow, approval/blocker explanations and safe Markdown;
   diff/log workspaces: file/step navigation, usable view controls, failure focus,
   clear loading and live-update behavior.
3. MR/Pipeline/Issue list summaries and filtering; Inbox grouping/current tasks
   and separate preferences, with the necessary data projections.

Acceptance criteria:

- At desktop size, current MR state, checks/approval blocker and the user's next
  action are available in the initial viewport regardless of description length.
- Changes shows useful code substantially earlier than the current ~542px start,
  supports file jumps, and keeps review/version context accessible.
- A failed Pipeline opens on the failed job/step; a reader can reach the actual
  failing output without scrolling through all dependency initialization.
- A running Pipeline never resets a chosen job, search location or scroll position
  unexpectedly; following the tail is an explicit state.
- Lists make state and relevant context comparable without opening every row.
- A merged/closed MR's historic notification cannot be mistaken for a live task.
- At 390px, no page-level horizontal overflow; essential state precedes secondary
  metadata, diff/log controls remain usable, and actions have adequate targets.
- Cover permissions, long text, empty/filter-empty states, stale versions, failed
  and queued runs, stream interruptions and large logs with meaningful fixtures.

## Guideline references

The following are the external principles consulted for the second pass.
The composition and priorities above are Moonhub-specific recommendations from
the actual pages, not claims that a reference prescribes this exact layout.

- [NN/g: 10 Usability Heuristics](https://www.nngroup.com/articles/ten-usability-heuristics/):
  state visibility, consistent behavior, error prevention, recognition and recovery.
- [NN/g: Tabs, Used Right](https://www.nngroup.com/articles/tabs-used-right/):
  distinguish navigation tabs from in-page tabs; keep simultaneously referenced
  information together and labels/selection unambiguous.
- [GOV.UK: Tabs](https://design-system.service.gov.uk/components/tabs/):
  suitable grouping and the costs of hiding content; short secondary details
  need not become tabs, and separate routes should not preload every panel.
- [W3C APG: Tabs Pattern](https://www.w3.org/WAI/ARIA/apg/patterns/tabs/):
  semantics and keyboard behavior for genuine in-page tab widgets.

## Implemented behavior and competitor references

The implementation retains the existing visual system and follows these
task-specific reference patterns, consulted on 2026-10-13:

- [GitLab diff versions](https://docs.gitlab.com/user/project/merge_requests/versions/)
  and [changed-file navigation](https://docs.gitlab.com/user/project/merge_requests/changes/):
  explicit revision context, file navigation and inline/side-by-side choices.
  Moonhub selects one stored revision with a native dropdown; comparison between
  two historical revisions remains outside this delivery.
- [GitHub workflow logs](https://docs.github.com/en/actions/how-tos/monitor-workflows/use-workflow-run-logs)
  and the [Gitea Actions job example](https://docs.gitea.com/usage/actions/quickstart/):
  job selection beside readable output, failure/step context and useful search.
  Following the user's specific correction, Moonhub logs flow with the page
  and have no fixed-height vertical scroller or whole-job collapse. Running
  output stays continuous. Completed logs longer than 200 lines show their first
  20 and last 80 lines; users can expand the middle. Follow is explicit, and
  search/error navigation reveals real matches even inside hidden middle output.
- [GitHub notification triage](https://docs.github.com/en/subscriptions-and-notifications/how-tos/viewing-and-triaging-notifications/managing-notifications-from-your-inbox):
  separate task filters and read state. Moonhub groups by resource before
  pagination and shows the resource's current state, preserving event history.

Pipeline overview now has Runs / Trigger events / Settings, selected server-side.
Trigger events link their actual generated runs independently of configuration
diagnostics. Dispatch choices come from real branch snapshots. MR readiness and
review controls share a side column; current-version reviews remain available
from Changes. Markdown escapes raw HTML and unsafe links. Issue lists use the
same compact headings, filters and status patterns.

Browser drafts are scoped to actor, form and MR revision in session storage,
with a 24-hour expiry and logout cleanup. Markdown supports bounded paragraphs,
headings, lists, quotes, fenced/inline code, strong text and safe links; it is
not a full CommonMark renderer. Inbox history shows the newest ten events per
resource. Enhanced running/search log windows render at most 5,000 lines;
completed log middles expand in batches of up to 1,000 lines. Search covers all
loaded output and Copy/Download include loaded output in the selected step(s).

Native tests, browser log regression, TypeScript checks and package-boundary
checks cover the data/permission and interaction changes. The isolated
`scripts/collaboration-ui-smoke.cjs` creates real local repositories, actors,
versions and runner output; its rendered data is a synthetic acceptance fixture.
It checks desktop 1440×1000 and phone 390×844, including no-script version
navigation, malicious Markdown/log text, draft recovery, tab permissions,
resource grouping, read watermarks and preservation of live reading position.
Screenshots and receipts are local evidence under `_build/collaboration-ui/`;
they are excluded from the source commit.

## Managed Markdown images extension (2026-10-19)

Issue and MR descriptions and comments, including MR discussion roots, inline
comments and replies, retain their native Markdown textarea for submission and
draft persistence. The enhancement adds Write / Preview / Add image, clipboard
paste and file drop. Keep the
restrained shared toolbar treatment and named native-button group with
`aria-pressed` on Write and Preview. This is local editor mode selection, not
another repository navigation layer.

Upload accepted PNG, JPEG, GIF and WebP files through the repository attachment
service and insert the returned managed URL at the insertion point. Show format
and size guidance, polite upload status and actionable failure text; retain the
draft and offer Retry upload for recoverable failures. Preview and submission
wait until uploads finish. Preview shows loading, empty and failure states;
Write restores editing. Existing managed Markdown remains usable in native
forms without JavaScript.
While an inline image upload is pending, selecting another code location keeps
the draft at its original lines, and Discard draft waits with explanatory status
until the upload finishes.

Toolbar controls have a (36px) desktop minimum height and (44px) at (900px) and
below, with wrapping rather than page overflow. Images remain private and
access-checked, render within (100%) of available width and a maximum height
(640px), and preserve aspect ratio. External image URLs remain text or links.
`docs/attachments.md` records limits, authorization, persistence and CLI behavior.

Browser and CLI acceptance passed for the extension. The three scoped P2
finishing findings were fixed; the final scoped disposition is ship. Desktop,
phone and preview evidence is recorded in
`.impeccable/review/attachments/desktop.png`,
`.impeccable/review/attachments/mobile.png` and
`.impeccable/review/attachments/desktop-preview.png`. This extends the existing
Operate identity without changing the broader collaboration composition.

## EasyMDE source editor extension (2026-10-20)

The user selected EasyMDE and requested an implemented preview. EasyMDE (2.21.0)
is the lazy-loaded source surface in `js/src/markdown-source.ts`;
`js/src/markdown-editor.ts` retains the existing Write / Preview / Add image
flow, managed image uploads and server-rendered preview. EasyMDE owns visible
source editing, selection and undo/redo history. Its changes synchronize with
the original textarea, which still owns form submission and draft persistence.
Hidden reply editors initialize when opened; disabled JavaScript and failed
enhancement loading preserve the native textarea path.

The formatting group exposes only Bold, Heading, Quote, Code, Insert link,
Bulleted list, Numbered list, Undo and Redo. It uses the existing Lucide icons
with accessible names, (36px) desktop targets and (44px) targets at (900px) and
below. Source typography stays restrained at (14px/1.65), with heading levels
1/2/3 at (1.3/1.2/1.1em). Lines wrap within the editor; Tab leaves the field.
EasyMDE does not download Font Awesome, upload images itself or show rendered
images in source. The established attachment service, permissions, limits and
safe server preview remain authoritative.

Image insertion uses source bookmarks that move with intervening edits while
uploads are pending; completed insertions participate in source undo history.
Preview/submission still wait for uploads. Inline draft anchoring, discard
protection, retry guidance and managed-image rendering retain the behavior
documented above.

Local browser acceptance passed for formatting and undo/redo, server preview
and source toggling, Unicode draft reload, asynchronous image insertion and
undo, mobile layout and native submission, lazy replies, inline anchor
cancel/reopen and keyboard submission, and the no-JavaScript textarea fallback.
The full CLI regression and attachment browser regression also passed. Native
Chinese IME composition has not been manually verified; Unicode draft coverage
does not establish that result. Independent scoped finish review returned ship
with no material fixes.

Preview evidence is recorded in `.impeccable/review/easymde/desktop.png`,
`.impeccable/review/easymde/mobile.png` and
`.impeccable/review/easymde/desktop-preview.png`; the browser acceptance receipt
is `.impeccable/review/easymde/receipt.json`. This records the implemented source
component within the existing Operate identity.
