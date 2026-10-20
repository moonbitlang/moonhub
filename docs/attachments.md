# Markdown attachments

MR and Issue descriptions and comments support managed images and files. MR
discussion roots, line/range comments and replies use the same service.
The first release keeps the Markdown source textarea and adds Write/Preview,
Attach files, clipboard file paste, file drop, upload status and retry. Plain forms
continue to work without JavaScript using existing managed attachment URLs.

## Limits and CLI

PNG, JPEG, GIF and WebP are recognized from file signatures and embedded as images
up to 5 MiB. Other files, including PDF, archives, logs, SVG and HTML, are accepted
up to 25 MiB and inserted as ordinary Markdown download links. SVG and HTML are
never rendered as active content. Empty files are rejected. A description or
comment can reference at most eight managed attachments in total. Rendering
only embeds managed repository image URLs; external image URLs remain text/links.

Use `moonhub attachment upload --repo compiler/moonhub --file /path/to/report.pdf`
to upload a file separately. The default output is ready-to-use Markdown; `--json`
returns `id`, repository-relative `url`, original `filename`, `media_type`,
decimal-string `byte_size` and `markdown`. Paste the result into a body file and
submit it with the existing description/comment commands. The upload remains
pending until a saved body references it. File paste requires a clipboard file
item; copying a local pathname as plain text does not upload that file.

CLI commands keep using `--body-file`. Markdown inline images such as
`![screenshot](data:image/png;base64,...)` are uploaded by the server and replaced
with stable `/<owner>/<repo>/attachments/<id>` URLs before saving. Code spans and
fenced code blocks are not converted. A body file and collaboration JSON request
are limited to 16 MiB, inline image bytes total at most 10 MiB per field, and the
resulting Markdown remains limited to 20,000 characters. CLI JSON output contains
the rewritten Markdown, never inline binary data.

`POST /-/api/v1/repos/:owner/:repo/attachments?filename=<name>` accepts raw file
bytes with a write-scoped Bearer token. It returns string `id`, repository-relative
`url`, original `filename`, `media_type`, decimal-string `byte_size` and `markdown`. Browser uploads use
`POST /:owner/:repo/attachments` with the existing form's CSRF token and scope
(`X-CSRF-Token` and `X-CSRF-Scope`). Browser preview posts UTF-8 Markdown to
`/:owner/:repo/markdown-preview` with the same protection.

## Persistence and authorization

Migrations 022/023 store metadata in `attachment`: repository, uploader, filename,
detected media type, byte count, SHA-256, creation time and lifecycle state. The
opaque ID is the storage key. Bytes live under `<repository-root>/.attachments/`,
outside all Git repositories, using owner-only directories/files. Uploads reserve
metadata, write a temporary file, rename it, then mark the attachment ready. Content
mutations and their `attachment_reference` rows commit in the same transaction.
Failed mutations leave only unclaimed pending uploads, never committed references
to incomplete uploads.

Reads recheck current repository access. Before an attachment is linked, only its
uploader can read or claim it. Linked attachments may be reused within the same
repository. Attachments cannot be linked or fetched through another repository.
Images use their detected media type. Other files use `application/octet-stream`
and `Content-Disposition: attachment`, with the original UTF-8 download filename.
All responses use `nosniff`, a restrictive CSP and private `no-store` caching.
Random URLs do not replace authorization. Migration 023 preserves existing image
metadata, reference claims and pending-upload lifecycle state. Ordinary Markdown
links claim references transactionally just like embedded images; code examples
do not claim files. Non-image attachments cannot be embedded using image syntax.

The server expires never-linked uploads after 24 hours, in hourly batches of up
to 100. Expiry claims prevent a concurrent content mutation from linking a file
being removed; interrupted cleanup remains retryable. Once an image has been
linked, retention is conservative: description edits and soft-deleted comments do
not delete its bytes. Restoring a comment retains the original image references.

## Backup and restore

Deployments already persist the repository root under `/data/repos`, so images
live under `/data/repos/.attachments`. The stopped-service backup in
`deploy/recovery.sh` copies all of `/data`, including the database, repositories
and image bytes. Restore that complete archive together. A database-only backup
does not contain images. Custom deployments must persist and back up both the
database and the complete repository root; images are not Git objects and cannot
be recovered by cloning repositories.
