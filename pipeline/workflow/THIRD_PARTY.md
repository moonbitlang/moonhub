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

`moonbit-community/yaml` is MIT-licensed and retained under `vendor/yaml`;
see that package's README for the event-boundary patch. Its lexer and parser
own all YAML syntax handling; Moonhub's event receiver only enforces workflow
input policy before using its standard tree loader.
