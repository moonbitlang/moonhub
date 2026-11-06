# Structured diff

The Web Changes and commit pages use MoonDiff 0.1.2 in Lexical mode, ignoring
comments and tests by default. AST and Line modes and both filters are available
in the toolbar. `.mbt` paths on either side select MoonBit comparison; other
files, including generated `.mbti`, use line comparison. Line mode disables
semantic filters. Git still owns immutable comparisons, renames, modes and blobs.

## API, CLI and MCP

`GET /-/api/v1/repos/:owner/:repo/mrs/:number/diff` retains its patch response
unless `format=structured` is explicit. Semantic options never affect patches.

Structured requests accept `version`, optional `commit`, `page` (1-based),
`mode=lexical|ast|line`, `ignore_comments=true|false` and
`ignore_tests=true|false`. A manifest contains protocol/engine versions,
`comparison_id`, fixed `base_sha`/`head_sha`, MR `version`, up to 100 `files`
and `has_more`. Generated interface files sort first, then paths sort lexically.
Filtering never removes files from this list. Git records are parsed as bounded
NUL-delimited bytes. Each file has an optional `path_error`: non-UTF-8 paths use
quoted byte-escaped display names and IDs derived from the original bytes.
Normal UTF-8 paths retain their existing IDs. If either path is invalid, that
file returns `document: null` and an error without reading blobs or launching a
worker. Web (including no-JavaScript pages) and CLI lists show the error; these
files have no retry button or structured inline comment controls. Other files
remain usable. Retain the returned MR version
and commit selection for later requests.

Adding `file_id` selects a file on that manifest page. File IDs are opaque and
resolved from the authorized comparison, never interpreted as object IDs or
paths. The response includes the raw file metadata, effective `options`,
`document_id`, and either `document` or a per-file `error`. All endpoints use
`Cache-Control: no-store` and authorize again after loading, including cache hits.
Cookie-authenticated browser endpoints are owned by their feature packages:
`/:owner/:repo/merge-requests/:number/diff` and
`/:owner/:repo/commit/:full-sha/diff`.

```sh
moonhub mr diff 12 --version 3 --format structured --json
moonhub mr diff 12 --version 3 --format structured --file-id FILE_ID --mode ast --ignore-tests false
```

`--page` selects the file page. Without `--json`, the CLI prints the file list or
declarations and original file line numbers, with terminal control characters
removed. `moonhub_get_merge_request_diff` accepts the same optional snake-case
parameters. Calling the MCP tool with its original parameters retains its patch
response. Its boolean options use the strings `true` and `false`, consistently
with the existing MCP argument schema.

## Document and comment coordinates

`document.kind` preserves `whole` or `top_level`; `sections` preserve matched,
inserted and deleted declaration identities, both declaration orders, local
fallbacks and ignored rows/segments. All exposed line numbers and section ranges
are **one-based coordinates in the original file**. Missing sides have no line
or range. `status` distinguishes identical content, changes, declaration
reordering, no structural changes and ignored-only content. EOL and final
newline metadata are independent of hunks, as are Git modes and renames. An
empty hunk list does not mean that a file did not change.

Structured inline comments submit `document_id`, `file_id`, `hunk_id`,
`diff_page`, `mode`, `ignore_comments`, `ignore_tests`, plus the existing
`version`, optional `commit`, `path`, `side`, `start_line`, `end_line` and `body`.
Use the **effective options** from the file response. CLI flags use hyphens.
MCP's `moonhub_comment_merge_request` accepts these fields too; specifying
`path` selects inline discussion creation.

The server resolves or recomputes the document, verifies its identity and checks
1–100 consecutive lines on one side within one displayed hunk. An obsolete
document identity requires refreshing the file while retaining the draft.
Calls without structured identity retain Git hunk validation. The stored anchor
schema is unchanged. Preparation happens before taking the repository write
lock; writing rechecks access, MR identity and the saved revision in the lock.
Old discussion contexts remain readable when filters hide their location.

Discussion/source links resolve the saved anchor against its complete fixed
comparison. Source links with `code` correct stale/missing `page` and `file_id`;
notification and post-comment links without a file page also locate the file.
Explicit pagination without `code` is respected. Redirects retain the version,
commit, discussion, reply and source target, without changing stored comments.
The target file is loaded by the server for no-JavaScript clients; the browser
scrolls to original file line numbers. Missing files or unavailable manifests
leave saved discussion context visible with an explanation.

## Worker and operation

Build before local tests or startup:

```sh
moon build --strip -j 1
export MOONHUB_DIFF_WORKER="$PWD/_build/native/debug/build/cmd/moonhub-diff-worker/moonhub-diff-worker.exe"
moon run --strip -j 1 . -- testdata/repos --assets ./assets
```

The runtime image installs `moonhub-diff-worker` on PATH. It reads one bounded
JSON request until stdin EOF, writes one JSON response and exits. The parent
writes stdin, reads stdout and drains stderr concurrently. Processes use hard
cancellation and are waited for before releasing an execution permit. The
worker imports only the pure protocol and calculation packages; the Web process
does not import MoonDiff's computation packages.

| Setting | Default |
| --- | --- |
| `MOONHUB_DIFF_WORKER` | `moonhub-diff-worker` |
| `MOONHUB_DIFF_CONCURRENCY` | 1 (allowed 1–64) |
| `MOONHUB_DIFF_DEADLINE_MS` | 5000 (allowed 1–60000) |
| `MOONHUB_WEB_MOONDIFF` | `true`; `false` restores Git patch pages |
| Queue | 16 waiting tasks, 2-second wait |
| Source | 1 MiB / 20,000 lines per side |
| JSON request / result | 16 MiB / 2 MiB |
| Retained stderr | 64 KiB, then continue draining |
| Shared manifest / file LRU | 64 entries / 32 MiB serialized UTF-8 |
| Git manifest output | 16 MiB |
| Context / graph budget | 3 / 3,000,000 |

Manifests and file calculations share the same execution permits and waiting
queue. Each stage acquires/releases its own permit, so file work never holds a
permit while waiting for a manifest. The configured deadline covers manifest
Git reads, parsing and sorting, or file blob reads, startup, communication and
calculation. Parsing yields every 256 records, with bounded scanning and chunked
sort/merge steps so deadlines and cancellation remain effective.

The executor caches complete sorted manifests by repository, fixed base/head
SHAs and protocol version; pagination, anchor lookup and file requests reuse
them. It rechecks the cache after admission. Manifest and file entries share
one typed LRU; entries larger than its byte budget return normally without
being cached. Waiting tasks hold descriptions only. Failed/cancelled work is not
cached. Manifest admission/deadline failures return retryable HTTP 503 responses
with `Retry-After: 2`; MCP reports the existing tool `isError` shape. Cache
identity includes repository directory, fixed SHAs, paths, blob IDs, options
and protocol/engine versions. The enabled Web startup verifies the
worker protocol and fails clearly if it is missing or incompatible. Structured
external requests remain available when the Web feature flag is off.

The application executor exposes cumulative counts, sizes and timings. Production
logs emit `event=diff` JSON with `phase=manifest|file` and cache hits or
queue/execution milliseconds,
cumulative input/output byte counts and termination reason; source content and
repository paths are excluded. No persistent process pool is used.

Browser files load when expanded and near the viewport, with at most two active
requests per view. Mode changes and disconnection abort the old generation;
obsolete results cannot replace it. React owns the custom element's appended
subtree; Rabbita owns page navigation. Shiki coloring runs in a browser worker
and preserves the server's row alignment and changed spans. SSR provides linked
file lists, options and selected-file contents without JavaScript.

## Initial measurements

On 2026-11-05, the native debug worker built with `--strip -j 1` compared the
repository's `gitops/operations.mbt` (13,052 UTF-8 bytes / 460 lines), changing one
error string. Three fresh processes per mode, including startup, measured with
`/usr/bin/time`:

| Mode | Wall time | Peak RSS | Response bytes |
| --- | --- | --- | --- |
| Lexical | 0.40–0.46 s | 15.6–16.0 MiB | 51,674 |
| AST | 0.43–0.48 s | 26.1–26.3 MiB | 7,783 |
| Line | below 0.01 s resolution | 6.6 MiB | 4,021 |

These are a small local sample under concurrent test load, not production
capacity measurements. The noncooperative worker regression additionally checks
that another Git operation completes while the CPU-bound worker is still running
and that timeout/cancellation leave no live process. Keep the conservative
single-task default until larger representative repositories have been measured.
