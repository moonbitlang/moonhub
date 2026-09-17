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

- In the last step, run `moon info && moon fmt` to update the interface and
  format the code. Check the diffs of `.mbti` file to see if the changes are
  expected.

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
