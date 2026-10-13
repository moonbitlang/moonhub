# CLI access-token UI

`/-/settings/tokens` connects a signed-in account to the Moonhub CLI and scripts.
It is a local extension of the existing account-settings UI. `PRODUCT.md` and
`DESIGN.md` remain the visual authority: preserve the restrained shell, white
workspace, neutral separators, system type, blue primary actions and existing
mobile navigation. No feature-specific visual identity or tokens are needed.

## Composition and behavior

Access tokens is available in the account menu and account-settings sidebar.
The page uses account navigation, a heading and short purpose statement,
optional error/new-token feedback, a separator list, and a bounded creation
form. Reuse `mr-list`, `form-stack`, `mr-form` and the shared field/button styles.

Each list row shows the token name, permission, expiry timestamp and explicit
Revoked/Not revoked state. An unrevoked row has a red outlined Revoke action
whose label includes the token name. Revoked rows omit the action. “Not revoked”
does not assert that the token is unexpired. The empty list says No access
tokens. Do not add invented token metadata, activity or counts.

The creation form has a required Name (maximum 100 characters), a native
Permission select, a required Expires in days number field (1–365), and a blue
Create token button. Initial values are Read only and 30 days. Preserve the
implemented permission choices and their labels:

| Value | Label |
| --- | --- |
| `read` | Read only |
| `write` | Read and collaboration writes |
| `execute` | Collaboration writes and CI execution |
| `merge` | Collaboration writes and merge submission |

Server validation errors appear above the list using `role="alert"`; the
creation form retains the submitted name, selected permission and expiry so
the user can correct the request. Creation and revocation use protected native
POST forms and remain usable without scripts.

Successful creation adds a New access token notice above the list. It instructs
the user to copy the token immediately and store it in a private file for CLI
login. The secret is shown once in a labeled, read-only field with autocomplete
and spellcheck disabled. The regular list contains metadata, never secret
values. Preserve this distinction; do not place real credentials in docs,
fixtures or visual examples.

## Accessibility and responsive constraints

Use visible labels, native input/select/button semantics, textual revocation
state and semantic list items. Inherit the shell's keyboard focus indicators,
skip link and accessible mobile drawer. Keep the destructive action labeled
with the affected token, rather than relying on red alone.

The form is a single column bounded by the existing `mr-form` width (720px,
760px on very wide screens). At 900px and below it inherits the mobile shell;
at 600px and below buttons inherit a 44px minimum height. Rows remain stacked
and long content wraps through shared list styles. Fields fill the available
width. Preserve the form's mobile fit and error-state values without adding
fixed widths or a table that forces horizontal scrolling.

## Sources and review evidence

- Rendering and routes: `web/views/account/tokens.mbt`.
- Navigation: `web/ui/navigation.mbt` and `web/ui/views.mbt`.
- Shared composition, tokens and responsive rules: `js/src/app.css`.
- Local captures: `_build/cli-smoke/tokens-desktop.png`, `tokens-mobile.png`,
  `tokens-error-desktop.png` and `tokens-error-mobile.png`. These capture list,
  form and retained-error-value layouts; the one-time secret state is described
  from source. Generated captures are review evidence, not product data.
