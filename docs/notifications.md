# Review Requests and Collaboration Notifications

Open **Inbox** from the site header or workspace sidebar (`/-/notifications`).
It includes unread updates, all notifications, ready MRs waiting for your review,
and open Issues assigned to you. Reading a notification does not complete a
review request or close an Issue. The header loads the current unread count and
refreshes it once per minute while the page is visible; the link works without
JavaScript. Lists are paginated at 50 items.

## Request and Complete a Review

On a ready MR's **Discussion** tab, the author or a repository/team administrator
can choose an active contributor under **Reviewers** and select **Request review**.
Site administrators are eligible reviewers. Authors cannot request their own
review. Each MR supports up to 16 requested reviewers.

An outstanding request for the same version is idempotent. Approving or
requesting changes completes that request; commenting alone does not. A completed
request offers **Request review again**, which sends a new notification without
withdrawing the existing review or weakening the merge gate. Withdrawing a review
returns the request to pending. Draft and closed MRs are absent from the review
queue; marking ready or reopening requests another review of the current version.

When source or target changes, reviews remain attached to their original version
and requested reviewers return to pending for the new comparison. The Web process
checks requested ready MRs in the background, including repositories without CI,
using a persisted five-second polling cursor per MR. A missing branch does not
prevent processing other MRs. A notification links to the version that generated
it; the review queue links to the current MR. Historical notifications remain
historical even after a request is completed.

Review requests route attention; they do not add required approvals or grant
permission to merge or execute proposed code. Existing branch protection and MR
check authorization continue to apply.

## Events and Subscriptions

Authors, Issue assignees, review requesters, requested reviewers and discussion participants are
subscribed automatically. **Unsubscribe from updates** mutes ordinary discussion
updates without being undone by later participation. Readers can explicitly
subscribe. Direct review requests and assignments still reach their named
recipient. Actors do not receive notifications for their own actions.

Events include comments, approvals, changes requested, review withdrawal, MR
versions/ready/reopen/close/merge, Issue assignment/close/reopen, checks awaiting
execution approval and current failed checks. Successful checks do not generate
separate reminders. Obsolete check failures do not notify. Repeated refreshes,
recovery and unchanged check results do not duplicate the same event.

Notifications, source activity and optional mail queue entries commit in one
SQLite transaction. The migration backfills subscriptions from existing authors,
assignees and activity without replaying old events.

All inbox queries, unread counts, notification actions and subscription changes
check current repository access and active account status. Requested-review
queues additionally require current contributor access. Losing access to a private
repository hides its notifications and prevents opening or modifying them.

## Email

Email is **off by default**. Enable **Email me about collaboration updates** in
the Inbox. New notifications use the existing site SMTP or file transport. An
account must have a deliverable email; enabling mail does not resend old updates.
Queued mail rechecks repository access, the account email, subscription and email
preference before claiming delivery. A direct assignment/review request can bypass
a discussion mute, but never the email preference or repository permission.

Email contains an event type and a repository-relative item path, with no comment,
diff or title content. Moonhub does not yet configure a public HTTP base URL, so
messages do not include an absolute clickable site URL. Open the indicated item
on your Moonhub instance. Site SMTP configuration remains shared with invitations
and password recovery.

## Upgrade and Verification

Schema migration 015 runs at Web startup. Upgrade Web and SSH together; restore
matching database/repository backups when rolling back to an older executable.
Identity-only export accepts schema 15 and continues to exclude repository and
collaboration data. Review-request worker lifetime belongs to Web.

```sh
moon check --deny-warn
moon fmt
moon info
moon test --strip -j 1
node scripts/check-package-boundaries.cjs
npm run build --prefix js
moon build --strip -j 1 --deny-warn
node scripts/notifications-smoke.cjs
```

The browser smoke requires Node with `node:sqlite` and Playwright/Chromium in
its module search path. It uses an isolated local database, fixture Git repository
and file mail outbox. It verifies request → changes requested → push → background
refresh → approval → merge, and captures desktop/mobile Inbox and MR pages under
`_build/notifications-smoke/`. It removes only its own temporary service/data;
screenshots, logs and a receipt remain. No production data or SMTP is touched.
