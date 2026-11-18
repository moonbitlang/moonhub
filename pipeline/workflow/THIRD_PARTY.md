# Parser Provenance

The workflow/job/step model, scalar/list/environment mapping, defaults precedence,
and generated step names are adapted from **mizchi/actrun v0.30.1**, commit
`3ea136d34e7ee071986bbaaad54e40aa496b8488`, by mizchi and contributors:

- https://github.com/mizchi/actrun/blob/v0.30.1/src/lib.mbt
- https://github.com/mizchi/actrun/blob/v0.30.1/src/parser.mbt
- https://github.com/mizchi/actrun/blob/v0.30.1/src/lowering.mbt

The upstream code is Apache-2.0, reproduced in this repository's root `LICENSE`.
These are modified portions, not an unchanged upstream module. Moonhub replaces
the handwritten YAML parser with `moonbit-community/yaml`, rejects unsupported
fields before mapping, bounds input complexity, rejects YAML aliases/tags and
unsupported fields, and supports the documented workflow subset. Public runtime
templates and generic downloaded-action execution are MoonHub additions. The upstream executor,
lowering IR, action resolvers, and transitive actrun dependencies are not imported.

MoonHub uses the MIT-licensed `moonbit-community/yaml` dependency to parse YAML.
Its event receiver enforces workflow input policy before the standard tree
loader runs. [Mooncakes package](https://mooncakes.io/docs/moonbit-community/yaml@0.0.10)
