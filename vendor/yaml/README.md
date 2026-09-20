# Vendored moonbit-community/yaml 0.0.6

Source: the published `moonbit-community/yaml@0.0.6` package, repository
https://github.com/moonbit-community/yaml.mbt. Package checksum:
`f359c3474a6aa274f83b486c44e0d01b2f35ecc544a70e46ee180eedc1487fd5`.

The upstream source, unit tests, and MIT license are retained. This is not a
replacement YAML implementation. Moonhub applies a small event-boundary patch:

- `MarkedEventReceiver` is `pub(open)` so external callers can implement the
  documented event API (it is readonly in the published package).
- Its callback may raise `YamlError`, and that error type is `pub(all)`. A
  receiver can therefore stop parsing immediately on a depth/node limit, rather
  than merely recording an error while the parser continues recursing.

Toolchain compatibility changes replace deprecated `Array::new` and
`StringBuilder::new` calls with constructors, and spell existing internal
assertions as `guard!`. These preserve the upstream assertion behavior rather
than disabling compiler warnings. Trait method calls use explicit dispatch
instead of deprecated implicit promotion. The parser/lexer algorithms are unchanged.
Public trait-derived methods are explicitly exported with `pub extend`, and
blackbox tests qualify the package's types with `@yaml` for newer toolchains.
Formatting and generated interfaces follow the project's current toolchain.

On upgrade, verify this patch, run the upstream tests and pipeline parser tests,
and remove the local copy when a compatible upstream release exposes the hook.
