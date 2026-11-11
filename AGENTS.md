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

## GitHub Collaboration

This repository uses GitHub (`moonbitlang/moonhub`) for code, Issues, PRs,
merges and CI. Use GitHub tools or `gh` for this repository's collaboration.
MoonHub's product CLI and APIs remain supported; see `docs/cli.md` when testing
or operating those features. Do not route this repository's development back
through the old MoonHub mirror or MR checks.

For MoonHub product operations, check `moonhub auth status --json` first and
reuse existing credentials or a supplied token file. Never print tokens, put
them directly in arguments, commit credential files, or broaden credentials to
bypass an authentication failure. HTTPS is required outside trusted local tests.
Creating a PR does not itself authorize approval, merge or production deployment.

Use a `codex/` branch, reusing a suitable active branch when available. For new
work, fetch GitHub `master` and preserve existing uncommitted work:

```sh
git fetch --no-tags origin master
git switch -c codex/<short-topic> FETCH_HEAD
```

The development remote is `git@github.com:moonbitlang/moonhub.git` (HTTPS is also
supported). Verify fetch and push URLs before pushing; remove obsolete MoonHub
push URLs from local clones. Do not use a remote with multiple push destinations.

Build browser assets before Web tests, run the checks above, relevant tests with
`--strip -j 1`, and the package-boundary check when imports change. Review and
stage only intended changes. Write PR descriptions to a UTF-8 temporary file and
use `gh pr create --base master --body-file /absolute/path/to/description.md`.
Verify the created PR and report its URL. Attach the PR to the chat when a
pull-request artifact tool is available.

GitHub `master` requires a PR, an up-to-date branch and the GitHub Actions check
`CI required`. No review approvals are required. Force pushes, deletion and
administrator bypass are forbidden. `Self-check`, `Docker SSH`, `Frontend checks`
and `Build and deployment regressions` run in parallel on GitHub-hosted Ubuntu
24.04 runners. A separate `Windows runner` job uses a Windows Server 2022 / 2025 matrix.
`macOS runner` builds/tests the ARM64 guest and slot lifecycle on macOS.
Only success from all six checks passes the aggregate gate.
See `docs/github-ci.md` for configuration and cutover status.

## Continuous Deployment

`.github/workflows/ci.yml` calls the reusable `deploy.yml` only after `CI required`
passes on a `master` push. Manual runs default to CI only; deployment requires
selecting `master` and setting `deploy` to true, and still runs full CI. PRs never
deploy. Updated PR runs cancel obsolete PR CI; active production deployments are
not canceled by newer runs.

Production images continue to build and publish on EC2. Keep the existing
OIDC/SSM path, environment restrictions, deployment locks, task draining, backups
and health verification. See `deploy/github-cd.md` for operation and recovery.
The old repository's outbound write mirror and automatic push CI must be disabled
as recorded in the cutover checklist; keep other repositories' CI and the
production read-only deploy key intact.
