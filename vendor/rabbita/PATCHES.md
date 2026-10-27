# Rabbita snapshot

Pinned to `moonbit-community/rabbita@0.16.7`, upstream commit
`c6bbd1b3b649d5f6ea6b21e6c42f8003ec41c367` from
https://github.com/moonbit-community/rabbita (module directory `rabbita/`).
The upstream Apache-2.0 license and tests are retained. The incomplete upstream
`html/readme_test.mbt` example is retained as `.mbt.example` because it refers
to undefined snippets. The HTTP package retains its intentional `Result` API,
with the new compiler style warning scoped off for that package.

MoonHub uses a workspace member so native SSR and the browser always compile
against identical source, including offline Docker builds.

The only functional patch makes `html/attrs.mbt`'s existing
`Attrs::attribute` method public. The template migration adapter must preserve
attributes such as `autocomplete="username"`, fractional bounds, custom element
data and boolean attributes exactly. The typed helpers do not cover all values;
assigning live `value` or `checked` properties during hydration could also erase
input made before the client loads. No renderer or hydration behavior is changed. Trailing whitespace in upstream documentation comments is removed to satisfy the repository pre-commit hook.

When upgrading, compare this patch against the public API, run the framework
HTML tests, MoonHub's native suite, and the browser SPA suite. Remove the patch
when upstream provides a general attribute setter.
