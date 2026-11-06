# Repository Webhooks

Repository owners, administrators and site administrators manage endpoints at
/:owner/:repo/settings/webhooks. The sidebar links to Webhooks. JSON API and
CLI access are also available. A collaboration token still needs the actor's
repository manager role; write permits changes and read permits inspection.
Readers and ordinary contributors cannot inspect configuration or payloads.

## Configure an endpoint

1. Add an HTTPS payload URL and a 16–256 character ASCII signing secret without
   spaces. Up to 20 hooks can exist per repository.
2. Select event groups and save. Only future committed activity is delivered;
   adding a hook does not replay existing history.
3. Use **Send test event**, then **Deliveries** to inspect the status, exact
   payload and per-attempt timestamps/HTTP status. Tests target only this hook,
   regardless of its selected groups.
4. Edit to pause, change subscriptions or rotate the secret. A blank secret keeps
   the current one. Secrets are never returned in HTML, API responses or logs.
   Saving cancels pending/sending deliveries; a request already in flight can
   still arrive. Redelivery sends the saved event to the current endpoint with
   its current secret. Deleting removes the hook and its delivery records.

Browser mutations require CSRF/session checks. Configuration edits use optimistic
versions and create repository audit records. Saving a hook makes the saving
manager its authorizing owner. The worker rechecks that owner's active account
and manager role immediately before transmission. Revoked ownership cancels queued
deliveries. Another manager can save the hook to take ownership.

The sender needs the signing secret, so it is stored in SQLite, like SMTP
credentials. Protect the database and backups as secrets. Endpoint URLs must not
contain credentials. Avoid query-string secrets: URLs are visible to managers.

## Events and payload v1

Every request is POST with Content-Type application/json. Payloads contain
schema_version (number 1), event, action, repository (id, full_name), and sender.
Persisted business events also contain occurred_at in UTC. IDs, resource numbers
and versions are decimal strings. This is a MoonHub contract, not a claim of
Gitea/GitHub webhook compatibility.

| Event group | Activity |
| --- | --- |
| push | Branch/tag creation, updates and deletion through managed Git writes, and MR merges. Includes ref, before, after; all-zero OIDs represent an absent ref. No-op/aborted updates are omitted. |
| issue | Issue activity: opened, comment, edit, assigned, close, reopen; includes an issue snapshot and activity body/ID. |
| merge_request | MR lifecycle, updates, comments/replies and merge queue/failure activity; includes title/body/state, branches, saved version and source/target SHAs. A target change uses action `retargeted`, with the new branch/version in the MR snapshot and the old/new branch names in the activity body. Discussion IDs preserve reply identity; inline roots include the saved anchor. |
| review | approved, changes_requested, withdrawn and explicit review_requested; requests include the reviewer ID. |
| workflow_run | Run creation and real state/conclusion changes, including completion; includes run number, workflow path, branch and pinned SHA. |
| ping | Explicit test event, sent only to the selected hook. |

Business events and delivery fan-out commit in the same SQLite transaction as the
source activity. Payloads retain event-time data. Subscription choices apply at
event creation. Retries can cause separate events to arrive out of commit order.
Comment delete/restore and review-request removal are not separate events in v1.

Push recording is independent of CI execution permission and works with CI
disabled. Ordinary contributors are included. Deploy-key push senders identify
type deploy_key and the key ID, never the creator, and do not authorize CI.
User push senders identify type user, ID and username. Direct filesystem ref
edits outside MoonHub are not a supported event source.

Git reference-transaction hooks persist prepared intents before Git commits.
Committed updates produce one event. After a crash between Git and SQLite,
recovery checks the actual ref under the repository write lock before publishing.
Ambiguous state requires operator inspection before another managed write. The
committed phase and recovery use the same deduplication identity. Background
recovery advances through repository-ID pages even when a repository fails,
then wraps to retry earlier repositories; a failing first page cannot starve
later repositories. The scan cursor resets harmlessly on worker restart.

## Verify signatures and deduplicate

- X-MoonHub-Event: event group.
- X-MoonHub-Event-ID: stable event ID shared by its subscribed deliveries.
- X-MoonHub-Delivery: stable delivery ID retained across retries/redelivery.
- X-MoonHub-Signature-256: sha256= followed by lowercase hexadecimal HMAC-SHA256
  over the **exact raw request body bytes**, using the configured secret.

Verify with a constant-time comparison before parsing/processing. Persist the
instance identity and delivery ID with the receiving transaction: delivery is
**at least once**, so duplicates are possible after a crash. Return any 2xx
promptly. Retries retain the body and identity; secret rotation changes the
signature for later explicit redelivery.

## Delivery and destination policy

The Web service runs the worker. Each delivery receives up to five attempts,
with delays of 10 seconds, 1 minute, 5 minutes and 30 minutes. Network, TLS,
response errors and all non-2xx statuses are retried. Redirects are never followed.
Requests have a 10-second overall deadline and a 32 KiB response-header limit;
informational HTTP responses are skipped until the final status, within the
same cumulative header limit and request deadline. Response bodies are not
retained. Expired one-minute leases recover after restart. Manual redelivery
adds up to five attempts and restarts the 10-second,
1-minute, 5-minute and 30-minute backoff sequence while retaining cumulative
attempt numbers and prior history.

Default egress permits HTTPS to public IPv4 destinations with system-root TLS
verification. The worker resolves once and connects to that exact checked
address, retaining the hostname for TLS/SNI and Host. Private, loopback,
link-local, multicast and reserved destinations are rejected. IPv6-only
endpoints, proxies and custom CAs are not supported in v1.

For trusted internal receivers an operator can allow comma-separated exact origins:

~~~sh
MOONHUB_WEBHOOK_ALLOWED_ORIGINS=https://hooks.internal.example,http://127.0.0.1:9000
~~~

Only a matched origin may use HTTP or private destinations. No wildcards;
scheme, hostname and explicit port must match. Compose forwards the setting to
Web and recovery preserves it in upgrade.env. Restart Web after changes. Feature
modules consume an app-scoped policy, never environment variables directly.

History has no automatic retention policy in v1. Deleting a hook removes its
deliveries/attempts; events remain until repository deletion. The worker is serial,
so slow receivers can delay later deliveries. This is not distributed HA.

## CLI and API

Keep configuration, including the secret, in a private UTF-8 JSON file (at most
64 KiB). Do not pass secrets on command lines. Example:

~~~json
{"url":"https://example.com/hooks/moonhub","secret":"replace-with-a-random-secret","events":["push","merge_request","review","workflow_run"],"active":true}
~~~

~~~sh
moonhub webhook create --repo compiler/moonhub --body-file /private/path/hook.json --json
moonhub webhook list --repo compiler/moonhub --json
moonhub webhook edit 1 --body-file /private/path/updated-hook.json --json
moonhub webhook ping 1 --json
moonhub webhook deliveries 1 --page 1 --json
moonhub webhook delivery 1 --delivery 42 --json
moonhub webhook redeliver 1 --delivery 42 --json
moonhub webhook delete 1 --version 2 --json
~~~

Edit JSON includes version as a decimal string. Omit secret or use an empty
string to keep it. Events is an array and active a boolean. Inspect the current
configuration/version before retrying a stale edit.

API prefix: /-/api/v1/repos/:owner/:repo/hooks

- GET / and POST /: list/create; POST /:hook: versioned edit.
- POST /:hook/ping and POST /:hook/delete (body contains version).
- GET /:hook/deliveries?page=1 and GET /:hook/deliveries/:delivery.
- POST /:hook/deliveries/:delivery/redeliver.

## Upgrade and verification

Migration 024 advances schema 23 to 24 without replaying history. Upgrade Web
and SSH together; SSH hooks record the new push intents. Back up and restore
matching SQLite and repository data before rollback; older binaries cannot open
schema 24.

~~~sh
moon check --deny-warn
moon fmt
moon info
moon test --strip -j 1
node scripts/check-package-boundaries.cjs
npm run build --prefix js
moon build --strip -j 1
node scripts/webhooks-smoke.cjs
~~~

The smoke requires Node with node:sqlite, Playwright/Chromium and Git. It creates
an isolated database, repository, session and HTTP receiver. It verifies exact
signature bytes, CLI/stale versions, Issue events, prepared tag recovery,
real receive-pack branch/tag creation and deletion, retry after server restart,
stable IDs, attempt history, no-JavaScript forms and
desktop/mobile rendering. Evidence: _build/webhooks-smoke and
.impeccable/review/webhooks.
