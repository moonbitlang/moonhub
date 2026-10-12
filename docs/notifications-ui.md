# Notifications UI

This feature extends the existing restrained, GitLab-inspired server-rendered
workspace. `PRODUCT.md` and `DESIGN.md` remain the visual authority: the same
global header, context sidebar, white workspace, neutral separators, system
type, Lucide icons and blue accent apply. These are local feature patterns,
not a new visual system.

## Personal Inbox

Signed-in users reach `/-/notifications` from the persistent header Inbox link
or the workspace sidebar. The Inbox uses workspace navigation; Issues and
Merge Requests retain repository navigation. The header badge is an optional
script enhancement: it hides at zero, caps its visible value at `99+`, and
includes the full unread count in the link's accessible name. The link itself
works without scripts.

The page composes a heading and subtitle, four wrapping filter links, a
separator list, pagination, then a bounded email-settings section. The filters
are Unread (with the user's actual count), Review requests, Assigned issues and
All notifications. Unread is the default. Each filter has its own explanatory
empty state; preserve the distinction between caught up, no pending reviews,
no open assigned issues and no notification history.

Rows show the event label, an explicit `Unread` label when applicable, a linked
title, and secondary repository/resource, actor, version and time metadata as
available. Do not fabricate missing metadata or counts. The title link opens
the resource; the separate `Read and open` POST action explicitly marks an
unread notification read before redirecting. Read rows and live task rows
without a notification ID omit that action. `Mark all read` is a neutral
heading action shown only on the first page when unread notifications and
items exist; its submitted boundary is the newest item in the returned list.
The list displays up to 50 items, with Newer/Older links preserving the filter.

Email notifications use a labeled checkbox and explicit Save notification
settings button. The checkbox reflects the saved preference; delivery uses
the site's email configuration. A successful save returns a status message.
Keep preference state distinct from any claim of successful email delivery.

## Discussion subscriptions and reviewers

`web/ui/notifications.mbt` owns the subscription form shared by Issues and Merge
Requests. Its neutral button toggles between Subscribe to updates and
Unsubscribe from updates. Keep the adjacent policy text: direct review requests
and assignments still notify the user after unsubscribing.

On a Merge Request, the subscription form follows version/source-target
metadata and appears across its views. The Discussion view adds an unframed
Reviewers section before the description and activity. Separator rows show
the reviewer's display name, Review requested/Review submitted status, and
version. An empty section says no reviewers have been requested yet.

The labeled native reviewer select and Request review action appear for an
editable, open, non-draft request on its latest version when candidates exist.
Completed reviewer rows offer Request review again under the corresponding
editable/open/non-draft/latest-version conditions. Preserve these visibility
rules and the version submitted with each request; do not add placeholder
reviewers or imply reviews apply to historical versions.

## Accessibility and mobile constraints

Use ordinary links and protected native POST forms, semantic list items,
labeled controls, named navigation/sections and `aria-current="page"` for the
selected filter. Unread and review state have text labels rather than relying
on color. Saved-settings feedback uses `role="status"`. Inherit the shell's
keyboard focus treatment, skip link and mobile drawer behavior.

At 900px and below, the shell uses its existing mobile navigation arrangement.
At 600px and below, Inbox rows stack their content and action, and subscription
buttons stack above their policy text. Filter links and reviewer actions wrap;
titles and metadata can break long words. Inherit 44px mobile buttons and the
existing responsive field sizing. Keep the email section within its `65ch`
maximum and avoid fixed row widths that cause horizontal page overflow.

## Implementation and visual references

- Inbox rendering/routes: `web/views/notifications/views.mbt` and `routes.mbt`.
- Reviewer composition: `web/views/merge_requests/merge_views.mbt`.
- Shared subscriptions: `web/ui/notifications.mbt`.
- Feature styles and inherited tokens: `js/src/app.css`; badge enhancement:
  `js/src/app-shell.ts`.
- Local smoke captures: `_build/notifications-smoke/inbox-desktop.png`,
  `inbox-mobile.png`, `review-desktop.png`, and `review-mobile.png`. These are
  generated review evidence, not durable fixtures or sources of product data.
