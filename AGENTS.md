# Project Agents.md Guide

This is a [MoonBit](https://docs.moonbitlang.com) project.

You can browse and install extra skills here:
<https://github.com/moonbitlang/skills>

## Project Structure

- MoonBit packages are organized per directory; each directory contains a
  `moon.pkg` file listing its dependencies. Each package has its files and
  blackbox test files (ending in `_test.mbt`) and whitebox test files (ending in
  `_wbtest.mbt`).

- In the toplevel directory, there is a `moon.mod` file listing module
  metadata.

## Package Boundaries

- See `docs/architecture.md` for package responsibilities and dependency
  direction. Keep the root package limited to the CLI and process entry point.
- Business packages must not import Web packages or Moonback, including in tests.
- Group Web features under `web/views/<feature>`. Each package owns its routes,
  rendering and HTTP tests; related list/detail/edit pages belong together.
  Page packages must not import sibling page packages. Put shared presentation
  in `web/ui` and request/session helpers in `web/context`.
- Web feature modules obtain app-scoped dependencies with `ctx.require` during
  initialization. Register dependencies in `web/dependencies.mbt`; keep custom
  bootstrap configuration reads at the application boundary.
- Import `test_support` and `web/testkit` only for tests, never in production
  packages. The Web testkit may reuse the lower-level test fixtures.
- Run `node scripts/check-package-boundaries.cjs` after changing package imports.

## Coding convention

- MoonBit code is organized in block style, each block is separated by `///|`,
  the order of each block is irrelevant. In some refactorings, you can process
  block by block independently.

- Do not add thin helpers that do not change behavior. A helper must reduce
  meaningful duplication, isolate a likely point of change, or encode a clear
  policy. Otherwise, call the underlying API directly.

- Try to keep deprecated blocks in file called `deprecated.mbt` in each
  directory.

## Tooling

- `moon fmt` is used to format your code properly.

- `moon ide` provides project navigation helpers like `peek-def`, `outline`, and
  `find-references`. See $moonbit-agent-guide for details.

- `moon info` is used to update the generated interface of the package, each
  package has a generated interface file `.mbti`, it is a brief formal
  description of the package. If nothing in `.mbti` changes, this means your
  change does not bring the visible changes to the external package users, it is
  typically a safe refactoring.

- Temporarily use `moon build --strip -j 1`, `moon test --strip -j 1`, and
  `moon run --strip -j 1 . -- ...` for native development. The 2026-09-11
  compiler (`moonc v0.10.12+ef027fb8a`) spends excessive CPU time generating
  native debug locations; `--strip` avoids that path while retaining `-O0`.
  Do not retry long-running unstripped builds or switch to release mode as a
  workaround. See README.md for evidence and the removal criteria. Keep this
  policy until a compiler update has been verified to fix the issue.

- Run `moon test --strip -j 1` to check tests pass. MoonBit supports snapshot
  testing; when changes affect outputs, run `moon test --strip -j 1 --update`
  to refresh snapshots.

- Prefer `assert_eq` or `assert_true(pattern is Pattern(...))` for results that
  are stable or very unlikely to change. For snapshot tests that record
  structured debugging output, derive `Debug` and use `debug_inspect`, rather
  than deriving `Show` for debugging. For solid, well-defined results (e.g.
  scientific computations), prefer assertion tests. You can use
  `moon coverage analyze > uncovered.log` to see which parts of your code are
  not covered by tests.

## Before Committing

Before every commit, run these commands in this exact order, stopping on the
first failure:

```sh
moon check --deny-warn
moon fmt
moon info
```

Review formatting and generated `.mbti` changes. Stage only the intended changes,
then rerun the sequence if the staged content changed. Do not commit with
warnings, skip failed checks, or automatically stage unrelated changes.

Enable the tracked pre-commit hook in each clone with
`git config --local core.hooksPath .githooks`. The hook requires tracked changes
and MoonBit inputs to be staged, runs the sequence above, and rejects unstaged
formatting/interface changes. It never stages files or stashes work. See
`.githooks/README.md` for the hook's scope and verification command.

## MoonHub Collaboration CLI

Use the MoonHub CLI for MR, Issue, Pipeline and Inbox operations. Prefer the
CLI to browser forms or ad-hoc HTTP requests. See `docs/cli.md` for the complete
command reference. If `moonhub` is not on PATH, build and invoke the local CLI
from the module root:

```sh
moon build --strip -j 1
_build/native/debug/build/moonhub.exe --help
```

The examples below use `moonhub`; substitute the executable path when using
the local build. The collaboration server is `https://moonhub-dev.mooncakes.io`
and this repository is `compiler/moonhub`.

### Authentication

Check `moonhub auth status --json` before collaboration commands. Reuse existing
credentials or a supplied token file. When signing in with a token file:

```sh
moonhub auth login --server https://moonhub-dev.mooncakes.io \
  --token-file /absolute/path/to/moonhub.token
moonhub auth status --json
```

Login saves credentials privately under `$XDG_CONFIG_HOME/moonhub/auth.json`,
or `$HOME/.config/moonhub/auth.json`. To use a token without saving a login,
pass `--server` and `--token-file` on each command. `MOONHUB_SERVER`,
`MOONHUB_TOKEN` and `MOONHUB_REPOSITORY` are also supported. Never print tokens,
put them directly in command arguments, or commit credential files. HTTPS is
required; `--allow-http` is only for trusted local development.

A `write` token is sufficient to create an MR and comment. CI execution needs
`execute`; merging needs `merge` and the account's repository permissions.
Obtain missing credentials through the user's authorized authentication flow;
do not create or broaden credentials merely to bypass an authentication failure.

### Branches, Checks and MR Creation

Use a `codex/` branch, reusing a suitable active branch when available. For new
work, fetch the latest target branch and start from it, preserving existing
uncommitted work. The MoonHub target branch is `master`:

```sh
git fetch --no-tags ssh://git@moonhub-dev.mooncakes.io:12222/compiler/moonhub.git master
git switch -c codex/<short-topic> FETCH_HEAD
```

Browser assets in `assets/` and `js/src/icons.generated.css` are generated and
ignored by Git. After cloning, run `npm ci --prefix js` and
`npm run build --prefix js` before Web tests or the local server. Rebuild after
changing frontend sources or dependencies; keep generated assets out of commits.
Run the commit checks above, relevant tests with `--strip -j 1`, and the package
boundary check when imports change. Review and stage only intended changes.

`origin` has both MoonHub and GitHub push URLs. Push explicitly to MoonHub when
creating an MR here; verify the diff against the fetched target contains only
the intended work:

```sh
git log --oneline FETCH_HEAD..HEAD
git diff --shortstat FETCH_HEAD...HEAD
git push ssh://git@moonhub-dev.mooncakes.io:12222/compiler/moonhub.git HEAD:refs/heads/codex/<short-topic>
```

Write a UTF-8 MR description to a temporary file (at most 20,000 bytes).
Describe the problem, resulting behavior and actual validation. Create the MR
after pushing, with explicit repository, source and target:

```sh
moonhub mr create --repo compiler/moonhub \
  --source codex/<short-topic> --target master \
  --title 'Concise change title' --body-file /absolute/path/to/description.md --json
moonhub mr view <number> --repo compiler/moonhub --json
moonhub mr checks <number> --repo compiler/moonhub --json
```

Verify the returned MR and report its URL. In Codex, attach the created MR to
the chat using the pull-request artifact tool.

### Follow-up Work

Use `--json` for machine-readable output; treat IDs, versions and cursors as
decimal strings. Read the MR's current version with `mr view` before operations
that require `--version`; state edits use `--edit-version`. After a stale-version
response, reload and review the new state before retrying. MR creation does not
by itself authorize review approval, check execution, or merge.

```sh
moonhub mr diff <number> --version <version> --repo compiler/moonhub --json
moonhub mr comment <number> --version <version> --repo compiler/moonhub \
  --body-file /absolute/path/to/comment.md
moonhub mr edit <number> --edit-version <edit-version> --repo compiler/moonhub \
  --title 'Updated title' --body-file /absolute/path/to/description.md
moonhub mr delete-comment <number> --comment <activity-id> --version <comment-version> \
  --repo compiler/moonhub
moonhub mr restore-comment <number> --comment <activity-id> --version <comment-version> \
  --repo compiler/moonhub
moonhub ci list --repo compiler/moonhub --json
moonhub ci view <run> --repo compiler/moonhub --json
moonhub ci logs <run> --attempt <attempt> --after <cursor> --repo compiler/moonhub --json
moonhub issue list --repo compiler/moonhub --status open --json
moonhub inbox --filter reviews --json
```
