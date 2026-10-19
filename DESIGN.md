---
name: Moonhub
description: Restrained GitLab-inspired workspace for code collaboration.
colors:
  primary: "#1769d2"
  primary-hover: "#1055b0"
  primary-soft: "#edf4ff"
  canvas: "#fff"
  surface-subtle: "#f7f8fa"
  text: "#20252c"
  muted: "#5d6877"
  border: "#e1e5eb"
  border-muted: "#edf0f3"
  success: "#1a7f37"
  success-soft: "#edf8f0"
  warning: "#986400"
  warning-soft: "#fff7e5"
  danger: "#c12d39"
  danger-soft: "#fff1f2"
typography:
  headline:
    fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif'
    fontSize: "24px"
    fontWeight: 650
    lineHeight: 1.35
    letterSpacing: "0px"
  title:
    fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif'
    fontSize: "17px"
    fontWeight: 650
    lineHeight: 1.4
  body:
    fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif'
    fontSize: "14px"
    fontWeight: 400
    lineHeight: 1.5
    letterSpacing: "0px"
  label:
    fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif'
    fontSize: "13px"
    fontWeight: 600
    lineHeight: "20px"
  metadata:
    fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif'
    fontSize: "12px"
    fontWeight: 400
    lineHeight: 1.5
  log:
    fontFamily: 'ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace'
    fontSize: "12px"
    lineHeight: 1.55
rounded:
  status: "4px"
  navigation: "5px"
  control: "6px"
spacing:
  micro: "4px"
  small: "8px"
  control: "12px"
  section: "16px"
  gutter: "24px"
  workspace: "32px"
components:
  button-primary:
    backgroundColor: "{colors.primary}"
    textColor: "{colors.canvas}"
    typography: "{typography.label}"
    rounded: "{rounded.control}"
    padding: "7px 12px"
  button-primary-hover:
    backgroundColor: "{colors.primary-hover}"
  button-secondary:
    backgroundColor: "{colors.canvas}"
    textColor: "{colors.text}"
    typography: "{typography.label}"
    rounded: "{rounded.control}"
    padding: "7px 12px"
  button-danger:
    backgroundColor: "{colors.danger}"
    textColor: "{colors.canvas}"
    typography: "{typography.label}"
    rounded: "{rounded.control}"
    padding: "7px 12px"
  field:
    backgroundColor: "{colors.canvas}"
    textColor: "{colors.text}"
    rounded: "{rounded.control}"
    padding: "8px 10px"
  page-navigation:
    textColor: "{colors.muted}"
    padding: "10px 2px"
  status-success:
    backgroundColor: "{colors.success-soft}"
    textColor: "{colors.success}"
    rounded: "{rounded.status}"
    padding: "3px 8px"
---

# Design System: Moonhub

## Overview

**Creative North Star: "Restrained GitLab-inspired workspace"**

Moonhub is an Operate interface: the user reads current state, finds the next
permitted action and works with code. The established left context navigation
and right workspace remain the organizing structure. White surfaces, cool
neutrals, compact system typography and one blue interaction accent keep the
interface quiet and task-focused.

Hierarchy comes from position, type weight, separators and selective disclosure.
Collaboration screens place resource identity and current state near each other,
while historical events, hashes and preferences use secondary treatments.
PRODUCT.md remains product authority; docs/collaboration-ui-plan.md carries the
surface brief. This document records the implemented visual system.

**Key Characteristics:**
- Restrained, task-focused workspace.
- Flat sections and separator-based lists.
- Textual state with semantic color support.
- Native server-rendered controls with progressive enhancement.

## Colors

Primary blue marks links, selected views, focus and the dominant action within a
task region. Hover and soft variants support interaction and selection. White is
the canvas and content surface; cool subtle surfaces distinguish the sidebar and
code. Dark text, muted metadata and two separator strengths provide hierarchy.

Success, warning and danger pair readable text with quiet tinted backgrounds.
Merged uses blue; queued/running/awaiting approval use warning; failed/error use
danger; cancelled/skipped and draft/closed use neutral treatments. Destructive
actions alone use red. Invitation acceptance and mail delivery remain distinct.

**The Textual State Rule.** Every status has a readable label; color alone never
communicates state, authorization or completion.

## Typography

Use the system sans stack for UI and the existing monospace stack for source,
logs, paths and hashes. The frontmatter records shared headline, title, body,
label, metadata and log roles. Small UI headings use body-sized semibold text.
Code views retain their existing syntax theme. Numeric counts and times use
tabular numerals; relative-time enhancements retain exact UTC information.

Discussion Markdown has line spacing (1.7) and an (80ch) maximum reading width,
with headings, lists, quotes, links and code rendered without arbitrary HTML.
Long titles, paths and discussion text wrap rather than forcing page overflow.

## Layout

The shell has a (56px) global header, a (224px) desktop sidebar, optionally
collapsed to (64px), and a fluid workspace. Default page padding is
(28px 36px 64px). The existing (4/8px) rhythm remains, with larger gaps between
task regions. Forms are bounded at (720px), increasing to (760px) on very wide
screens. Code and diffs use available width. Sidebar preference persists locally.

MR detail has a flexible main column and a (280px) readiness column separated
by a light vertical rule, with a (32px) gap. The side column is sticky and holds
merge status, checks, reviewers, review composition and preferences. At (1100px)
and below it moves before the main content; at (700px) and below it becomes one
column and enhanced reviewer details start collapsed.

Pipeline detail has (190px) job navigation beside selected output. At (700px)
and below navigation moves above logs. Logs use natural page scrolling without
a fixed-height vertical scroller. Diff navigation uses a (150px) column, changing
to a compact horizontal file strip on phones; its code canvas retains bounded
code-view scrolling.

At (900px) and below the shell becomes an enhanced mobile drawer; no-script
navigation remains in document flow. At (600px) buttons inherit a (44px) minimum
height. Filters stack at (700px), Inbox rows/actions at (600px). Pipeline, Issue
and Inbox page links stay one horizontally scrollable row with a clear selected
view. The mobile drawer is dismissible and keyboard-accessible.

**The Navigation Roles Rule.** Context navigation chooses scope, page links
choose a feature view, filters narrow records, local selectors choose a job,
step, file or revision, and buttons perform actions. Preserve those distinctions.

## Elevation & Depth

Sections are flat and unframed. Lists and task regions use separators; surface
tints indicate selection, code or feedback. Floating account, context and row
menus share the menu shadow recorded in the sidecar. Do not turn task regions
into elevated cards.

Drawer motion is brief (180ms ease-out), diff disclosure motion (120ms ease).
Reduced-motion preferences disable transitions and minimize animations. Live
feedback does not announce every log line or move focus during polling.

## Shapes

Controls and code containers have modest rounded corners; status labels are
slightly tighter and context navigation subtly rounded. Buttons have a (36px)
desktop minimum height; shared text fields begin at (38px). Borders remain thin
and neutral. Lucide icons are consistently (18px), with accessible names on
icon-only controls. Account avatars retain their circular shape.

Focus uses a visible blue outline (2px), offset (3px); native fields also change
their border on focus. Preserve the skip link, visible labels, semantic headings,
named navigation and native disclosure semantics.

## Components

### Buttons and fields

Blue is primary, white with neutral outline is secondary, and red is destructive
(filled or outlined). Hover strengthens the same role; disabled controls use
muted neutrals. Failed forms preserve input. Enhanced busy forms retain values
and reject duplicate submission. Native selects and protected POST forms are
the baseline.

### Navigation and records

Page links have muted text, a stronger selected label, blue underline and
aria-current. They retain ordinary link keyboard behavior, not a tab-widget
model. Separator rows place identity/state together and metadata beneath. Empty
and filtered-no-result states explain their actual situation.

Pipeline overview uses Runs / Trigger events / Settings, defaulting to Runs;
Settings remains manager-only. Event processing, workflow diagnostics and run
results are separate states. Diagnostics use disclosure, not an unrelated run
failure badge. Issue lists have Open / Closed, title search and assignment
filters.

### Managed Markdown image editor

Keep the native, labeled Markdown textarea as the source of truth for Issue and
MR descriptions and comments, including discussion roots, inline comments and
replies. Progressive enhancement adds a quiet, wrapping toolbar with Write,
Preview and Add image. These are native buttons in a named group; Write and
Preview expose their selected state with `aria-pressed`, stronger text and a
neutral outlined surface. They are not page navigation.

The toolbar joins the textarea with a subtle surface, thin neutral border and
modest top corners (6px). Controls have a desktop minimum height (36px), rising
to (44px) at (900px) and below. Add image stays at the trailing edge in interaction
blue. Hover uses the white surface; focus has a visible blue outline (2px),
offset (2px). Dragging files over the textarea uses the same outline. Preview
keeps the editor width, a minimum height (140px) and content padding (12px).

Add image, clipboard paste and file drop upload PNG, JPEG, GIF or WebP files, up
to (5 MiB) each, then insert managed Markdown at the insertion point. Keep format
and size guidance directly below the editor. Upload state and actionable errors
use polite textual status; preserve the draft, offer Retry upload for recoverable
failures, and explain when to choose another file or reload. Wait for uploads to
finish before previewing or submitting. Preview disables Add image and presents
loading, empty and failure messages; Write restores editing.
While an inline image upload is pending, selecting another code location keeps
the draft at its original lines, and Discard draft waits with explanatory status
until the upload finishes.

Rendered images use the private, access-checked repository attachment service.
They remain inside the reading column (maximum width 100%, maximum height
640px), preserve aspect ratio and use modest corners (4px), without cropping.
External image URLs remain text or links. Native forms still accept existing
managed image URLs without JavaScript. `docs/attachments.md` owns limits,
authorization and storage behavior.

### MR review and Changes

Discussion / Commits / Changes are URL-backed. A labeled native version select
lists real revisions newest first and marks Latest. Enhanced change navigation
retains a View submit fallback. Historical selections keep their warning and
version-bound action restrictions. Revision commits and preferences use secondary
disclosure. Readiness keeps permission reasons beside actions, including why an
author cannot self-approve.

Changes has file navigation, Split/Unified selection and Wrap lines. Desktop
defaults to split; (900px) and below to unified unless manually chosen. Wrap starts
enabled. File selection expands and jumps to that file. Existing file folding
and large-diff disclosure remain. The raw patch fallback stays until enhancement
is ready. Review composition remains beside the selected revision. Draft text
survives view navigation through session storage, with unload protection when
storage is unavailable.

### Pipeline logs

Logs are open output, never a whole-log disclosure. Job/step selection stays
coupled to output and recorded in the URL. Failed/running jobs are preferred
initially; manual selection survives updates. Exit codes appear only for terminal
steps. Queue, retry and stopped-update feedback is textual and grounded in data.

Running output stays continuous without a hidden-middle control. Completed,
fully loaded output over (200 lines) shows the first (20) and last (80) numbered
lines, with a middle button manually revealing up to (1000) more lines per press.
Search includes hidden middle output and navigates matches. The implementation
limits continuous rendering to a (5000-line) window and search navigation to
(1000 matches), with explicit feedback. Copy/download include all loaded output
for the selected step scope.

Wrap, Follow, End, All steps, error-keyword navigation, copy and download are
secondary controls. Follow is opt-in and stops when scrolling away. Polling
preserves page position, pauses in hidden pages and reports interruption. Search
highlights matches and distinguishes the current match. Feedback uses polite
status announcements.

### Inbox groups

Inbox groups resources before pagination. Rows show current resource status,
linked title, repository/number and actual unread count. Review/assignment tasks
are distinct from historical updates; merged/closed resources explicitly identify
history. Recent activity uses native disclosure with event-specific links and
actor/version/time metadata, showing its history limit. Mark read is explicit.
The four filters remain one horizontal row on phones. Notification settings is
a separate view linked from the heading, with a labeled email preference and save
feedback. Shared subscriptions retain the direct-request/assignment exception.

## Do's and Don'ts

### Do:
- **Do** preserve the restrained shell, shared tokens and native controls.
- **Do** keep identity, current state and the next permitted action close together.
- **Do** distinguish page navigation, filters, selection and action visually.
- **Do** retain textual status, visible focus and useful no-script fallbacks.
- **Do** use actual revisions, counts, workflow choices and log output.
- **Do** preserve submitted values, draft text and manual selection during updates.

### Don't:
- **Don't** add elevated cards or decorative typography to routine task regions.
- **Don't** make color alone carry status or permission meaning.
- **Don't** present historical updates or trigger diagnostics as current work.
- **Don't** fold the entire log or add a nested vertical log scroller.
- **Don't** wrap Pipeline, Issue or Inbox page navigation into unrelated rows.
- **Don't** fabricate metadata, diagnoses, approval bypasses or unsupported actions.
