# Browser rendering

MoonHub uses Rabbita for a hydrated, document-level SPA. The native server and
the JS entry point compile the same `web/spa.document` view. A direct visit
renders real HTML with Rabbita `App.render`; `web/client.start` calls
`App.hydrate` to adopt it. Initial fields use HTML attributes rather than live
property assignments, preserving input entered before JavaScript loads.

## Migration boundary

Feature route handlers and their existing Moonback templates still resolve
page data on the server. `web/ui.page_middleware` adapts their trusted, escaped
full-page output into `web/spa.Page`, a serializable tree of elements, string
attributes and text. It is intentionally not a general HTML parser or a path
for accepting untrusted HTML. Markdown sanitization and repository authorization
remain upstream of this boundary. This first migration installs the common
Rabbita rendering and navigation foundation; it does not rewrite every feature
as independent client-side components or move business services into the browser.

The middleware runs around the existing browser error/authentication stack:

- Normal document requests get SSR HTML, safe initial page JSON and the Rabbita
  hydration transcript. Raw-text script termination is escaped in the JSON.
- Requests accepting `application/vnd.moonhub.page+json` get the authorized page
  tree, retaining the original status, cookies and redirects. The same routes
  validate mutations and CSRF tokens. Private pages are not put in a client cache.
- Page responses use `Vary: Accept` and `Cache-Control: no-store`. Markdown
  preview fragments, JSON APIs, static files and streaming responses keep their
  existing protocols.

The client requests a page tree and updates Rabbita state; it does not inject a
replacement HTML document. Each committed navigation changes a keyed page
lifetime. Before Rabbita removes the old page, an AbortController disposes its
editor instances, event listeners, observers, timers and in-flight polls.
React-based code/diff custom elements retain ownership of their internal DOM
and unmount on disconnection. Their module is loaded after initial hydration.
The document head, including its title and styles, stays under Rabbita.

## Navigation and forms

`js/src/app-shell.ts` owns same-origin links, GET/POST form transport, URL/history,
focus and scroll restoration. External links, modified clicks, downloads,
non-page endpoints and forms requiring native encodings keep browser behavior.
`data-native-navigation` opts a link or form out of SPA handling.

Navigation aborts stale requests and serializes DOM commits. A successful POST
follows the server's redirect, and submitter values and CSRF fields are preserved.
A lost mutation response is never automatically replayed: entered text remains
available with an error message. Pending uploads block navigation; drafts retain
the existing session-storage behavior. Back/forward fetches current authorized
state rather than restoring cached private page data. A changed hashed app-shell
asset triggers a full visit to pick up the new deployed client. Initial bootstrap
scripts are removed after hydration so stale authorized state is not retained in
the document head.

`js/src/page-shell.ts` retains the current sidebar, menus, drafts and accessibility
behavior. The migration does not change the site's visual design.

## Framework source and builds

Both SSR and JS use the published `moonbit-community/rabbita@0.17.0` dependency
declared in `moon.mod`. The template adapter uses its public `Attrs::attribute`
escape hatch; no local framework patches are needed. The dependency base downloads
the package before offline application builds. Rabbita is Apache-2.0 licensed;
its license text is identical to the root `LICENSE`, which the final images also
install as `rabbita-LICENSE`.
The project builds as a single module. The native debug CLI is:

```sh
_build/native/debug/build/moonhub.exe --help
```

Build the browser before starting the server, because its manifest is loaded
once at startup. Restart the server after rebuilding assets:

```sh
npm ci --prefix js
npm run build --prefix js
moon build --strip -j 1
npm run check --prefix js
moon test --strip -j 1
node scripts/check-package-boundaries.cjs
```

The JS build first compiles `web/client` to ESM, then Vite bundles it with the
existing browser modules. Generated `assets/` files and icon CSS stay ignored.
Docker's asset stage copies the shared SPA and client packages. Its native and
browser stages resolve the same published Rabbita version. The dependency base
cache key includes `moon.mod` and the dependency resolver; application source
changes do not invalidate it. The deployment compiler remains pinned.

## Browser regression suite

With Node 24, the native debug build and browser assets available:

```sh
cd js
npx playwright install chromium
npm run test:browser
```

The suite starts its own loopback server on port 18092, clones the Git fixture
and creates an isolated temporary database. It tests initial DOM identity and
pre-hydration input, no-JS pages, SPA/history navigation, POST validation and lost
responses, login/logout, issue creation, Markdown preview/editor remounting,
private repository authorization and CSRF. Its server and fixtures are cleaned
up afterward; it never opens the development database.

`PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH` selects an existing compatible Chromium.
`MOONHUB_TEST_URL` skips the managed fixture server and targets an explicitly
prepared disposable fixture with the same users and repository. Do not point
these mutation tests at a development or production service.
