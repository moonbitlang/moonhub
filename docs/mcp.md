# MCP 2.0

MoonHub exposes a native MCP server at `https://YOUR-MOONHUB/-/mcp`,
implementing protocol revision **2026-07-28** with stateless Streamable HTTP
and JSON responses. It reuses existing business services, authorization,
repository locks, attachment handling, branch rules and version checks.

## Connect

Configure a client supporting revision 2026-07-28 with the HTTP endpoint
`https://YOUR-MOONHUB/-/mcp` and an `Authorization: Bearer <access-token>`
header. Create a token under **Account > Access tokens**; see
[CLI authentication](cli.md#authentication). Store the token in the client's
secret store or environment, never repository configuration or URLs.

This release uses MoonHub personal access tokens as a custom bearer strategy.
It does **not** provide OAuth discovery/registration/login/refresh. Clients
requiring OAuth instead of a configured bearer header cannot connect directly.
Cookie sessions do not authenticate MCP.

Only the modern per-request protocol is supported. Clients using the legacy
`initialize` handshake (2025-11-25 and earlier) need an upgrade or an external
adapter. There is no stdio transport, protocol session, GET/SSE channel,
stream resumption or DELETE-session endpoint. GET and DELETE return 405.
Legacy session headers are ignored.

## Requests

Every request is a separate POST with these headers:

```http
Content-Type: application/json
Accept: application/json, text/event-stream
Authorization: Bearer <access-token>
MCP-Protocol-Version: 2026-07-28
Mcp-Method: server/discover
```

```json
{
  "jsonrpc": "2.0",
  "id": "discover-1",
  "method": "server/discover",
  "params": {
    "_meta": {
      "io.modelcontextprotocol/protocolVersion": "2026-07-28",
      "io.modelcontextprotocol/clientCapabilities": {},
      "io.modelcontextprotocol/clientInfo": { "name": "my-client", "version": "1.0.0" }
    }
  }
}
```

Discovery returns `supportedVersions: ["2026-07-28"]` and `capabilities:
{ "tools": {} }`. All results include `resultType: "complete"` and server
identity in `_meta["io.modelcontextprotocol/serverInfo"]`. Discovery and tool
lists return `ttlMs: 0`, `cacheScope: "private"`; HTTP uses
`Cache-Control: no-store`. Each request works without prior discovery.

For `tools/list`, change the method in the body and `Mcp-Method` header.
The deterministic catalog is returned in one page; omit `cursor`.
For `tools/call`, also set `Mcp-Name` to the tool name, and include:

```json
{
  "jsonrpc": "2.0",
  "id": "mr-1",
  "method": "tools/call",
  "params": {
    "name": "moonhub_get_merge_request",
    "arguments": { "repository": "compiler/moonhub", "number": "19" },
    "_meta": {
      "io.modelcontextprotocol/protocolVersion": "2026-07-28",
      "io.modelcontextprotocol/clientCapabilities": {}
    }
  }
}
```

Request IDs may be strings or exact integers in the range
`-9007199254740991` to `9007199254740991`. Larger IDs must be strings. Numeric
IDs are checked against their original JSON token before executing a tool, so
fractional values cannot pass validation through floating-point rounding.

Tool results provide `structuredContent` and the same JSON as text in `content`.
Arguments follow the published JSON Schema 2020-12 schemas: all values are
strings, including IDs, versions, pages and `draft: "true"`. Unknown fields,
missing required fields and non-string arguments are rejected. Schemas have no
external references or `x-mcp-header` parameters. The `Mcp-Name` Base64
sentinel encoding is supported and validated against the body.

## Tools and permissions

The catalog describes arguments and effects. All 30 tools are discoverable
independently of token scope; each invocation enforces that scope and current
repository access. Tool names have the prefix `moonhub_`:

| Permission | Tool suffixes |
| --- | --- |
| `read` | `get_user`, `list_repositories`, `list_merge_requests`, `get_merge_request`, `get_merge_request_diff`, `get_merge_request_checks`, `list_merge_discussions`, `list_issues`, `get_issue`, `list_runs`, `get_run`, `get_run_logs`, `list_inbox` |
| `write` | `mark_notification_read`, `create_issue`, `comment_issue`, `edit_issue`, `close_issue`, `reopen_issue`, `create_merge_request`, `comment_merge_request`, `edit_merge_request`, `reply_merge_discussion`, `resolve_merge_discussion`, `reopen_merge_discussion` |
| `execute` | `create_run`, `rerun_run`, `cancel_run`, `approve_merge_checks` |
| `merge` | `merge_merge_request` |

`execute` and `merge` each include `write` but are independent. Tokens
never create repository roles. MR creation does not approve CI. Merging needs
manager access, an explicitly observed MR version and passing branch checks.
Edits use `edit_version`; discussion resolution uses `state_version`.
Reload current state after stale-version errors.

Paged issue/MR/activity/discussion and Inbox queries return up to 50 entries.
Discussion lists contain previews and the three most recent replies per thread.
Pass `discussion` to `moonhub_list_merge_discussions` to return a full
`discussion` object, including the complete saved anchor context and root/reply
bodies. In this mode `page` selects a 50-reply page in chronological order, and
`has_more` reports whether another reply page exists.

CI logs use `after` and return `next_cursor`, `has_more` and `complete`.
Clients poll unfinished CI using fresh requests. The server does not advertise
Tasks, subscriptions, resources, prompts, roots, sampling, elicitation or MCP Apps.

## Deployment and limits

The normal Web application mounts MCP; no additional process, JavaScript
runtime, migration or token type is needed. Use HTTPS in deployment.
Native clients normally omit `Origin`. When it is sent, configure an exact
trusted-origin allowlist at the application boundary:

```sh
MOONHUB_MCP_ALLOWED_ORIGINS=https://trusted-client.example
```

Multiple origins may be comma-separated. By default all presented origins are
rejected. `null`, unlisted and multiple origins receive 403. This setting
does not enable CORS/preflight for browser JavaScript. Wildcards are unsupported;
Host and forwarded headers cannot expand the allowlist.

Request bodies are limited to 64 KiB with a 10-second read deadline. Admission
control allows 120 requests per account per 60-second window; 429 includes
`Retry-After: 60`. At most 4096 account buckets are retained, with expiry.
Limits are per application instance; use a gateway for shared replica limits.
Git operations and log reads retain their existing execution/output bounds.

Malformed JSON returns -32700; invalid envelopes -32600; invalid params -32602;
unknown methods HTTP 404 / -32601; header failures HTTP 400 / -32020;
unsupported versions HTTP 400 / -32022 with `data.supported` and
`data.requested`. Authentication/scope failures return HTTP 401/403.
Business errors return HTTP 200 with `isError: true`. Unexpected errors are
redacted. Notifications are rejected without a JSON-RPC body and never execute
tool mutations.

Descriptions, comments, diffs and logs are untrusted data. Clients should let
users approve or deny consequential operations, especially execution and merge.
Token possession does not constitute user approval of every operation.

## Validation and references

Build browser assets if missing, then run:

```sh
moon check --deny-warn
moon fmt
moon info
node scripts/check-package-boundaries.cjs
moon test --strip -j 1 web/mcp
moon test --strip -j 1
```

Official specification: [base protocol](https://modelcontextprotocol.io/specification/2026-07-28/basic),
[HTTP transport](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http),
[discovery](https://modelcontextprotocol.io/specification/2026-07-28/server/discover),
[tools](https://modelcontextprotocol.io/specification/2026-07-28/server/tools),
[version negotiation](https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning).
