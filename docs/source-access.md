# Source and dependency access

New workflows with downloaded actions or `contents: write` use assignment v17.
Old saved definitions retain their previous protocol and source semantics.
Every dependency request checks the live worker attempt, execution identity,
lease, cancellation, requester, provider and deployment approval. Private
dependencies are available to trusted branch push, manual and scheduled runs.
PR and tag-push events retain the existing secret-event restrictions.

## Administrator grants

Both API mounts expose `GET` and `POST /repos/{owner}/{repo}/dependency-grants`.
They require a site administrator and a personal access token with the matching
read/write scope. The path identifies the consuming workflow repository. POST
uses optimistic `version` (`"0"` creates; GET returns current revisions).

For a private GitHub action, submit:

```json
{"kind":"github","target":"organization/private-action","ref":"","credential":"<repository-scoped Contents-read credential>","version":"0"}
```

The credential is write-only. The administrator must provision a credential
limited to that GitHub repository; MoonHub cannot inspect the credential's
external permissions. MoonHub sends it only to the configured repository's
GitHub commit/archive API. The bounded downloader passes it through stdin,
never command arguments, URLs or job environments. Archive redirects may only
target that repository on `codeload.github.com`; the Authorization header is
not forwarded. The job receives only the pinned commit and archive. The
implementation uses GitHub's [commit API](https://docs.github.com/en/rest/commits/commits#get-a-commit)
and [archive API](https://docs.github.com/en/rest/repos/contents#download-a-repository-archive-tar).

For a private MoonHub repository, submit an exact source ref:

```json
{"kind":"moonhub","target":"team/dependency","ref":"refs/heads/main","version":"0"}
```

Full branch/tag refs and 40-character commit IDs are supported. The source
repository identity is also bound, so deleting and recreating a path cannot
silently reuse a grant. Removal uses the same kind/target/ref, current version
and `"delete": true`. GitHub credentials may be omitted on deletion. Grants are
rechecked even for a previously resolved dependency. There are at most 64 grants
per consumer, 256 pinned dependencies per run family and 4096 internal dependency
authorization operations per worker attempt.

The first successful resolution is persisted under the public run ID. Retries,
parallel consumers and reruns reuse that commit after current authorization.
Public GitHub actions retain their anonymous download path when no matching
grant exists. Unshared private actions fail anonymous access without receiving
another repository's credential.

## Checkout and history

```yaml
permissions: {contents: read}
jobs:
  release-notes:
    runs-on: self-hosted
    steps:
      - uses: actions/checkout@v6
        with: {fetch-depth: 0}
      - run: git describe --tags && git log --oneline
      - uses: actions/checkout@v6
        with:
          repository: team/dependency
          ref: refs/heads/main
          path: vendor/dependency
```

The primary checkout stays at the captured run SHA. Full-history export includes
its complete ancestor graph and tags whose commits are ancestors of that SHA.
The default checkout stays shallow. Secondary checkout requires a separate
relative path with no symbolic links and an explicitly granted ref, then checks
out its saved SHA.
It does not receive general read access to that repository.

Exports retain the 64 MiB bundle and 10,000-file current-tree limits. Full history
also limits expanded Git objects to 256 MiB, the object enumeration to 4 MiB,
tags to 4096 and Git work to 30 seconds. Exceeding a budget fails with a source
limit diagnostic. Submodules and LFS do not inherit these grants.

## Job-token Git pushes

```yaml
permissions: {contents: write}
jobs:
  update:
    runs-on: self-hosted
    steps:
      - uses: actions/checkout@v6
      - run: |
          git config user.name 'Release automation'
          git config user.email 'release@example.test'
          git checkout -b generated-update
          echo updated > generated.txt
          git add generated.txt
          git commit -m 'Update generated file'
          git push origin HEAD:refs/heads/generated-update
```

Checkout disables credential persistence and sets a non-secret push URL to
`https://HOST/-/api/v1/repos/OWNER/REPO/git`. `github.token` is installed through
an invocation-local, URL-scoped Git authorization header; it is absent from
arguments and persistent Git config. The `/api/v3` mount offers the same
transport. Use HTTPS outside trusted local tests. Redirects are disabled.

Only the job's repository and `contents: write` permission are accepted. The
trusted receive hooks recheck authorization and the existing protected-ref
rules before commits. Protected branches, internal refs and protected release
tags retain their restrictions. Receive packets are bounded to 64 MiB, responses
to 4 MiB and transfers to 60 seconds. A private temporary server file binds the
hook to the live job and is removed on success or failure. `MOONHUB_BIN` selects
the installed server executable for the hook, defaulting to
`/usr/local/bin/moonhub`.

Job pushes retain mirror/webhook bookkeeping but do not enqueue workflow
trigger events. Read-only, expired, completed, cancelled and unrelated-repository
tokens are rejected. These endpoints do not grant SSH or general GitHub access.
