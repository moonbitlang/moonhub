# Repository UX alignment

Repository pages use Code / Issues / Pull requests / Actions / Settings above a
feature sidebar where applicable. Code uses the full content width without a
feature sidebar; its file pages keep their directory navigation. The global drawer
holds workspace destinations. The UI remains
English, uses MoonHub branding and the light theme, and keeps the existing
Rabbita document navigation, React code view and EasyMDE editors.

## Coverage

| Area | Implemented presentation |
| --- | --- |
| Shared shell | Persistent repository tabs; independent global drawer; feature sidebars; manager-only Settings; keyboard focus restoration and native details fallback |
| Code and commits | Branch/tag picker, bounded file finder, green SSH Code menu, head commit summary with a right-aligned Commits history link, root-only Releases summary, safe README preview, directory navigation, line references, exact text/path copy, Markdown Preview/Code switch |
| Create/import | Shared owner, name, visibility and source fields; existing queued/running/failed feedback, retry, discard and Refresh behavior |
| Issues | Title search, Open/Closed filters, All/Assigned to me sidebar, compact rows, discussion cards, assignee/related PR/subscription rail, independent close/comment actions and `#` copy references |
| Pull requests | User-facing PR names with unchanged `/merge-requests` routes; base ← compare; normal/draft selection; Conversation/Commits/Files changed; version-aware review panel; reviewers in the right rail; checks and merge readiness below Conversation |
| Files changed | Existing MoonDiff navigation, file/declaration collapse, Unified/Split, Line/Token/AST controls and explicit filter state; Review changes before the diff; immediate inline comments |
| Actions | Existing `/pipelines` routes; workflow navigation for workflows in the current result, Trigger events, status/branch/workflow filters; job/step/log navigation; manual Run workflow page; snapshot rerun distinguished from latest branch revision |
| Releases | Root Code page summary of the latest stable release; version/commit/time/status cards, safe Markdown notes, native collapsible Assets download list; existing draft → CLI/API upload → publish lifecycle |
| Settings | Branch protection, Actions configuration, Secrets/Variables, Webhooks, Deploy keys and Mirrors in one sidebar; adjacent Secrets/Variables tabs; member Variables under Actions; native confirmation before removing branch protection |

The file finder uses authorized server-side Git reads. It includes at most 5,000
paths, bounds Git output to 2 MiB, and provides a notice and folder-navigation
fallback when the index reaches its limit or cannot be decoded. README previews
are bounded to 256 KiB. Branch/tag choices distinguish same-named references;
ambiguous choices use object identities. No recursive browser crawl is used.

Code directory pages place **Commits**, with a history icon, at the right of the
head commit summary above the files. The subject and hash open commit details;
Commits opens `/commits?rev=...` with the current branch, tag or commit. No total
is inferred from the bounded history query. Empty repositories keep an empty
history link without a commit-detail link. File pages retain **History**.

Only the repository root displays a Releases summary, including roots selected
through branch, tag or commit navigation. Its 296px rail has a 32px gap; at 900px
and below it follows the README. The existing release service's `latest` policy
chooses the stable version, including an explicitly pinned latest release. Drafts
and prereleases alone show “No stable releases published.” with a release-list
link. Repository page initialization obtains the app-scoped service with
`ctx.require`; only root directory requests read the summary. Child directories,
files, commits and release pages omit it. The page package imports the business
`releases` package; it does not import another feature page package.

`/` focuses a visible page search field, `t` opens the code file finder and Esc
closes menus with focus restored. Typing inside inputs, editors or editable
content does not trigger navigation shortcuts. New listeners share the existing
page AbortSignal. Editor drafts, in-flight upload protection, duplicate submit
protection, polling disposal and no-script links/forms remain in use.

## Deliberate differences

- Pull requests retain `!123`; Issues retain `#123`, including copied references
  and safe Markdown links.
- MoonDiff keeps its current Token/AST and filtering defaults. Line mode is an
  explicit choice. No batch of unpublished inline comments is simulated.
- Search controls expose only existing title, actor/reviewer, status, branch and
  workflow capabilities. PR Open/Merged/Closed filters stay separate. No totals
  are invented.
- Labels, Milestones, Projects, Star/Fork, web editing, Blame, ZIP downloads,
  HTTPS clone and browser-reencoded raw downloads are absent.
- Release assets upload through the existing CLI/API. Published release and
  asset immutability, authorization and download byte streams are unchanged.
- The backend routes, query/form keys, CSRF scopes, version checks, redirects,
  permissions, schema, workers and business packages are unchanged.

## Verification and screenshots

The versioned [UX review and screenshot gallery](repository-ux-review.md)
explains each workflow change, includes six before/after comparisons and populated
desktop/mobile pages, and records validation results and remaining smoke limits.
The 36 original browser screenshots are in `docs/images/repository-ux/`.

Browser acceptance uses disposable repositories and databases. The Git used for
acceptance must support `merge-tree --write-tree`; this acceptance run uses Git
2.43.7 installed in `_build/repository-ux/tooling/git/bin`, while `/usr/bin/git`
is 2.34.1. Put a supported Git on `PATH` for native and browser tests.
`MOONHUB_BROWSER_PORT` selects the managed browser fixture port without disturbing
an existing local service. `PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH` selects an
installed Chromium for both Playwright and the updated UI smoke scripts.

The new `js/tests/repository-upload.spec.ts` verifies blocked navigation and
submission during upload, retained inputs on failure, and successful retry.
`js/tests/repository-ux.spec.ts` exercises 320, 390, 900 and 1440px,
repository tab selection, drawer keyboard operation, shortcut input exclusion,
URL/history filters, file preview/copy/anchors, PR drafts/review preservation,
release Markdown/publication, root-only release placement, revision-preserving Commits
links, empty history, sidebar-free SPA transitions, retained collapse preferences,
and no-script file navigation at all four widths. Existing suites
cover hydration identity, lost submissions, editor remounts, uploads, private
access, branch paths, historical revisions, inline review and diff scrolling.

Run browser assets before native Web tests:

```sh
npm run build --prefix js
npm run check --prefix js
moon check --deny-warn
moon fmt
moon info
moon build --strip -j 1
moon test --strip -j 1
node scripts/check-package-boundaries.cjs
MOONHUB_BROWSER_PORT=18197 npm run test:browser --prefix js
```

Local delivery artifacts are in `_build/repository-ux/`: the acceptance receipt,
command logs and before/after screenshots. They contain disposable fixtures,
not development or production data. Screenshots are not build inputs.

Interaction references: [cli/cli](https://github.com/cli/cli),
[VS Code](https://github.com/microsoft/vscode),
[MoonBit documentation](https://github.com/moonbitlang/moonbit-docs), and
[GitHub review workflow](https://docs.github.com/en/pull-requests/how-tos/review-pull-requests/reviewing-proposed-changes-in-a-pull-request).
