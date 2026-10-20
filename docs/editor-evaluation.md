# Markdown editor component evaluation

Assessment date: 2026-10-20. This is a proposal and an isolated feasibility
assessment, not a production editor replacement. No application dependencies
were changed for these experiments.

## Recommendation

Implementation decision (2026-10-20): the user selected EasyMDE for the first
integration. The current implementation uses EasyMDE 2.21.0 with the existing
textarea as the submission/draft boundary and server-rendered preview. The
comparison below records the assessment that preceded that decision; its GitHub
toolbar preference does not override the selected component.

For the next small improvement, retain the existing textarea, server preview,
attachment service and draft lifecycle. Add formatting controls with GitHub's
`@github/markdown-toolbar-element`. It adds the features currently missing from
the source editor with a small incremental download and a narrow integration.

If syntax highlighting, Markdown-aware indentation, editor-managed history,
position tracking and larger documents justify replacing the editing surface,
use a focused CodeMirror 6 configuration. It is the preferred full source-editor
engine for MoonHub; it does not require adopting a rich-document storage format.

Do not introduce WYSIWYG only to obtain a formatting toolbar. MDXEditor and
Milkdown remain candidates if rich editing becomes a product requirement.
Keep Atlassian in the comparison, but its document model and conversion work
make it a poor first choice for the current source-only requirement.

## Requirements that determine the choice

- Markdown strings remain the persisted and CLI-visible content. Preserve text
  constructs that the editor does not understand; avoid parse/serialize cycles
  during an ordinary source edit.
- The original form remains submittable, with no-JavaScript textarea fallback.
  Drafts, edit versions, pending upload state and code anchors retain ownership
  in the existing collaboration forms.
- All candidates reuse the existing managed image upload/read service, CSRF,
  repository authorization and server preview. Editor adoption does not replace
  attachment storage or change the CLI inline-image protocol.
- Opening many reply forms or moving the native inline composer must not create
  an editor instance for every hidden discussion. More substantial editors
  should load on demand and mount only when needed.
- Input method composition, keyboard navigation, mobile touch selection and
  undo/redo require explicit acceptance. Programmatic Unicode insertion is not
  evidence of compatibility with a real Chinese input method.

## Candidate comparison

Versions below were resolved from the npm registry on the assessment date.
The assessment distinguishes browser-tested source candidates from candidates
reviewed through official documentation and published package source only.

| Candidate | Examined version | Fit for the current requirement | Principal trade-off |
| --- | --- | --- | --- |
| GitHub Markdown toolbar | 2.2.3 | Preferred incremental enhancement | Formatting controls over the native textarea; no syntax highlighting or independent editor document model |
| CodeMirror 6 | view 6.43.15, state 6.7.6, commands 6.11.1, lang-markdown 6.5.2 | Preferred full source editor | Own the small form/preview/upload adapter and load it only when needed |
| EasyMDE | 2.21.0 | Viable ready-made alternative | Uses CodeMirror 5; some supplied UI/preview/upload behavior duplicates MoonHub features |
| UIW React MD Editor | 4.1.2 | Viable if a React-owned editor is preferred | Textarea-based, but introduces a React root/controlled value and an additional preview stack |
| ByteMD | 1.22.0 | Secondary option | Markdown source, plugins and upload callback, but published code uses the CodeMirror 5 family and adds its own renderer/plugin stack |
| Vditor | 4.0.1 | Better for a requirement that includes multiple editing modes | Source mode exists, but initialization still loads Lute; output normalizes text in observed cases |
| TOAST UI Editor | 3.2.2 | Secondary option | Source and WYSIWYG modes exist; latest npm release examined is from 2023-02-17, with an older dependency set |
| MDXEditor | 4.3.3 | Future rich-editing shortlist | Markdown input/output and a source/diff plugin, built around Lexical/MDAST conversion |
| Milkdown / Crepe | 7.22.3 | Future rich-editing shortlist | ProseMirror-based Markdown-rich editing; buying that stack just for source editing adds integration work |
| Tiptap + Markdown | Markdown 3.32.0 | Future custom rich editor | JSON/Markdown conversion and custom extension work; official Markdown documentation still identifies early-release limitations |
| Atlassian Atlaskit Editor | core 239.0.0, markdown-transformer 6.3.1, bitbucket-transformer 10.2.3 | Keep as a reference, not the first integration | Rich-document model, ecosystem dependencies and separate import/export work |

GitHub's `@github/text-expander-element` 2.9.4 is a separate possible enhancement
for mentions or issue references. It is not needed for formatting or image
uploads and should not enter the initial change without the corresponding
product behavior.

## Measured download sizes

Method: isolated npm installation, exact versions, esbuild 0.25.12, ES2022 ESM,
production/minified build, gzip level 9. These are comparative experiment
measurements, not the incremental bytes of a future Vite production integration.
CSS, adapter code and dynamically loaded assets are excluded unless stated.
Shared-React measurements externalize React and ReactDOM because the application
already uses React. Registry unpacked sizes are not used as browser bundle sizes.

| Configuration | JavaScript gzip | Notes |
| --- | ---: | --- |
| Existing MoonHub textarea enhancement | 2.4 KiB | Existing upload/status/preview code measured separately |
| GitHub formatting toolbar | 3.6 KiB | No runtime npm dependencies; styling remains application-owned |
| GitHub text expander | 4.2 KiB | Optional, measured separately from the toolbar |
| CodeMirror 6 source configuration | 100.4 KiB | CommonMark language, highlighting, Markdown/default/history keymaps, wrapping and history; no full HTML language support |
| CodeMirror 6 default markdown() configuration | 170.6 KiB | Demonstrates why configuration matters; includes additional language support |
| EasyMDE | 108.7 KiB | CSS adds about 3.1 KiB gzip; disable automatic external font loading for self-hosting |
| UIW nohighlight, React shared | 134.4 KiB | Component CSS adds about 1.9 KiB gzip; production preview should still use the server |
| UIW default, React shared | 355.5 KiB | Includes the default highlighting/preview stack |
| Vditor entry alone | 72.8 KiB | Incomplete total: Lute is loaded separately |
| Vditor Lute runtime | 581.2 KiB | Additional JavaScript required even by the tested source-mode initialization |

Vditor also has locale, icons and CSS assets: the examined English locale,
Ant icon script and CSS total about 21.2 KiB gzip. A deployment must serve the
required assets locally instead of leaving the default CDN behavior in place.
The source-mode experiment used a local asset base and made no off-origin
requests. Individual gzip sizes are approximate accounting, not one combined
compression result.

## Browser experiment results

An isolated headless Chromium page mounted CodeMirror, EasyMDE, UIW and Vditor
against the same nine fixtures: Chinese/emoji, lists/tasks, reference links,
managed image text, tilde fences, trailing spaces/blank lines, raw HTML text,
CRLF and a document without a final newline. This checks source preservation,
not whether the production server renders every fixture's syntax.

- CodeMirror and EasyMDE preserved the eight non-CRLF fixtures exactly. Their
  default configurations normalized CRLF to LF. CodeMirror separately preserved
  CRLF when configured with its line-separator facet; a line-ending policy must
  be deliberate rather than reported as universal byte-for-byte preservation.
- UIW's controlled string preserved all nine initial strings, but native
  textarea/FormData serialization normalized CRLF. Form submission remains a
  separate integration concern.
- Vditor preserved seven fixtures exactly; CRLF normalized and getValue added a
  trailing newline to the no-final-newline fixture. Published source confirms
  this source-mode normalization. Its raw initial textarea and getValue can
  differ, so the form must sync through the chosen canonical path.
- CodeMirror's mapped state position and EasyMDE's bookmark preserved an image
  insertion point while Chinese/emoji text was inserted before it. Both passed
  the explicit image insertion undo/redo check. UIW/Vditor need a position/history
  adapter; lack of that adapter in this experiment is not proof they cannot
  support the behavior.
- The four mounted source configurations did not overflow a 390px Chromium
  viewport with the tested long line. This is not mobile Safari/Android testing.
- The GitHub toolbar formatted a Chinese/emoji-containing selection, emitted
  input events, submitted the resulting Markdown through the original textarea
  and undid the formatting in Chromium. It supplies toolbar focus management.
  Its published implementation includes execCommand and fallback paths; verify
  undo and focus on the supported browser matrix before shipping.
- No page errors or off-origin requests were observed in the final local run.

Not verified: real Chinese IME composition on macOS/iOS/Android, mobile WebKit,
screen-reader operation, full production discussion mount/move/dispose behavior,
or a full rendering/security review of every candidate. Those are integration
acceptance criteria, not capabilities inferred from version numbers.

## Atlassian-specific findings

Do not describe Atlaskit as a ready-made Markdown textarea. Jira's documented
Atlassian Document Format is JSON, and the editor package imports its rich
document schema and plugin ecosystem.

The examined `@atlaskit/editor-markdown-transformer` 6.3.1 exposes both parse and
encode in its types, but the published encode implementation throws
`This is not implemented yet`. The separate Bitbucket transformer does serialize
editor nodes to Markdown; its parse path consumes HTML. Combining these pieces
may support an import/export pipeline, but it is not an automatically lossless
Markdown source editor. Managed image nodes and unsupported syntax need their
own compatibility tests.

The core package declares Apache-2.0. The examined Markdown transformer has a
metadata inconsistency: package.json declares MIT while its included LICENSE
contains Apache-2.0 text. Resolve the upstream discrepancy and inspect the actual
dependency set before adoption; do not infer a uniform license from a product
name. This records the observed files, not a legal conclusion.

## Suggested next implementation

1. Define a small textarea adapter for formatting, insertion, value changes and
   focus, with the existing native form as the boundary. Keep upload and preview
   behavior application-owned.
2. Add only formatting that the server preview and saved-content renderer both
   support. Current bounded rendering does not implement italic, task-checkbox
   rendering, tables or strikethrough. Do not display controls for those features
   until the renderer contract and tests cover them.
3. Use the GitHub toolbar for bold, links, code, quotes, supported headings and
   lists, with existing icons and mobile touch sizes. Keep Add image connected
   to the attachment service rather than the generic image-URL command.
4. Verify source/form round trips, undo, Chinese IME, pending uploads with cursor
   movement, nested reply drafts, inline anchor retention and no-script fallback.
   A later CodeMirror upgrade should pass this same contract and lazy-load on
   first use.

This recommendation does not require a storage migration or a CLI format change.
It improves the current source editor first and leaves a measured path to a more
capable source surface.

## Primary sources and reproducibility

Package versions, release timestamps, dependencies and declared licenses were
read from each package's npm registry metadata and its published tarball.

- GitHub toolbar: https://github.com/github/markdown-toolbar-element
- GitHub text expander: https://github.com/github/text-expander-element
- CodeMirror APIs: https://codemirror.net/docs/ref/
- CodeMirror Markdown: https://github.com/codemirror/lang-markdown
- EasyMDE configuration: https://github.com/Ionaru/easy-markdown-editor
- UIW source: https://github.com/uiwjs/react-md-editor
- ByteMD source: https://github.com/bytedance/bytemd
- Vditor source/runtime configuration: https://github.com/Vanessa219/vditor
- TOAST UI configuration: https://github.com/nhn/tui.editor/blob/master/docs/en/getting-started.md
- MDXEditor source mode: https://mdxeditor.dev/editor/docs/diff-source
- MDXEditor architecture: https://mdxeditor.dev/editor/docs/overview
- Milkdown architecture: https://milkdown.dev/docs/guide/architecture-overview
- Tiptap Markdown: https://tiptap.dev/docs/editor/markdown
- Atlassian document format: https://developer.atlassian.com/cloud/jira/platform/apis/document/structure/
- Atlassian published transformer source: https://unpkg.com/@atlaskit/editor-markdown-transformer@6.3.1/dist/esm/index.js
- Atlassian Bitbucket transformer: https://unpkg.com/@atlaskit/editor-bitbucket-transformer@10.2.3/dist/esm/index.js

Full temporary evidence for this session is in
`/tmp/moonhub-editor-eval-20261020/`: packages.json, sources.json, extracted
published sources, and spike/package-lock.json, measure.mjs, bundle-results.json,
browser-entry.mjs, browser-test.cjs and browser-results.json. The exact installed
versions and measurement commands are recorded there. Temporary evidence is
not required by the application build and may be removed by the operating system.
