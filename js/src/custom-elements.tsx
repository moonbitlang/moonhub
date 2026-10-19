import {
  type CodeViewDiffItem,
  parsePatchFiles,
  setCustomExtension,
  type CodeViewLayout,
  type CodeViewItem,
  type FileDiffMetadata,
  type CodeViewLineSelection,
} from "@pierre/diffs";
import {
  CodeView,
  type CodeViewHandle,
  WorkerPoolContextProvider,
} from "@pierre/diffs/react";
import { type CSSProperties, type ReactNode, type RefObject, useMemo, useRef, useState, useEffect, useLayoutEffect } from "react";
import { createRoot, type Root } from "react-dom/client";
import DiffWorkerUrl from "@pierre/diffs/worker/worker-portable.js?worker&url";

type MoonBitLanguage = "moonbit";

const largeDiffLineThreshold = 500;

const codeViewLayout = {
  paddingTop: 0,
  gap: 1,
  paddingBottom: 0,
} as const satisfies CodeViewLayout;

const codeViewUnsafeCSS = `
[data-diffs-header] {
  container-type: scroll-state;
  container-name: sticky-header;
}

@container sticky-header scroll-state(stuck: top) {
  [data-diffs-header]::after {
    position: absolute;
    bottom: -1px;
    left: 0;
    width: 100%;
    height: 1px;
    content: "";
    background-color: var(--moonhub-diff-border);
  }
}
`;

const codeViewOptions = {
  layout: codeViewLayout,
  overflow: "wrap",
  theme: "github-light",
  themeType: "light",
  stickyHeaders: true,
  diffIndicators: "classic",
  lineHoverHighlight: "number",
  unsafeCSS: codeViewUnsafeCSS,
} as const;

const codeViewShellStyle = {
  "--moonhub-diff-border": "var(--color-border)",
  "--moonhub-diff-muted": "var(--color-muted)",
  "--moonhub-diff-hover-bg": "var(--color-surface-subtle)",
  "--diffs-font-family":
    "\"M PLUS Code Latin\", \"SF Mono\", Monaco, Consolas, \"Ubuntu Mono\", \"Liberation Mono\", \"Courier New\", monospace",
  "--diffs-font-size": "13px",
} as CSSProperties;

const moonhubCodeViewStyles = `
.moonhub-code-view-frame {
  overflow: hidden;
  min-width: 0;
  border: 1px solid var(--moonhub-diff-border);
  border-radius: 6px;
  background: #fff;
}

.moonhub-code-view-toolbar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  padding: 8px 12px;
  border-bottom: 1px solid var(--moonhub-diff-border);
  background: #f6f8fa;
  color: var(--moonhub-diff-muted);
  font-size: 12px;
  line-height: 1.4;
}

.moonhub-code-view-toolbar button {
  flex: 0 0 auto;
  appearance: none;
  border: 1px solid var(--moonhub-diff-border);
  border-radius: 6px;
  padding: 4px 8px;
  background: #fff;
  color: #1f2328;
  font: inherit;
  cursor: pointer;
}

.moonhub-code-view-toolbar button:hover {
  background: var(--moonhub-diff-hover-bg);
}

.moonhub-code-view {
  position: relative;
  min-width: 0;
  width: 100%;
  font-size: 13px;
  overflow-x: clip;
  overscroll-behavior: contain;
  overflow-anchor: none;
}

.moonhub-code-view diffs-container {
  overflow: clip;
  contain: layout paint style;
  box-shadow:
    0 -1px 0 var(--moonhub-diff-border),
    0 1px 0 var(--moonhub-diff-border);
}

.moonhub-collapse-diff-button {
  display: inline-flex;
  flex: 0 0 auto;
  align-items: center;
  justify-content: center;
  width: 24px;
  height: 24px;
  margin-left: -8px;
  padding: 0;
  border: 0;
  border-radius: 6px;
  appearance: none;
  background: transparent;
  color: var(--moonhub-diff-muted);
  cursor: pointer;
}

.moonhub-collapse-diff-button:hover {
  background: var(--moonhub-diff-hover-bg);
  color: #1f2328;
}

.moonhub-collapse-diff-button:disabled {
  cursor: default;
  opacity: 0.45;
}

.moonhub-collapse-diff-button span {
  width: 8px;
  height: 8px;
  border-right: 1.5px solid currentColor;
  border-bottom: 1.5px solid currentColor;
  transform: rotate(45deg);
  transition: transform 120ms ease;
}

.moonhub-collapse-diff-button[data-collapsed="true"] span {
  transform: rotate(-45deg);
}

`;

setCustomExtension("mbt", "moonbit");
setCustomExtension("mbti", "moonbit");

type InlineThread = { id: string; oldPath: string; newPath: string; side: "old" | "new"; start: number; end: number; href: string; label: string; preview: string; node: HTMLDetailsElement | null };
type InlineReview = { threads: InlineThread[]; target?: string; form: HTMLDetailsElement | null };
type InlineLocation = { id: string; path: string; side: "old" | "new"; start: number; end: number };

// Only displayed, contiguous lines on one side can form an immutable anchor.
function inlineLocation(items: CodeViewItem<undefined>[], selection: CodeViewLineSelection | null): InlineLocation | undefined {
  const item = items.find(item => item.id === selection?.id);
  if (!selection || item?.type !== "diff") return;
  const { range } = selection;
  const side = range.side ?? "additions";
  const start = Math.min(range.start, range.end);
  const end = Math.max(range.start, range.end);
  if ((range.endSide && range.endSide !== side) || start < 1 || end - start >= 100) return;
  const displayed = item.fileDiff.hunks.some(hunk => {
    const first = side === "deletions" ? hunk.deletionStart : hunk.additionStart;
    const count = side === "deletions" ? hunk.deletionCount : hunk.additionCount;
    return start >= first && end < first + count;
  });
  if (!displayed) return;
  return {id: item.id, path: side === "deletions" ? item.fileDiff.prevName ?? item.fileDiff.name : item.fileDiff.name, side: side === "deletions" ? "old" : "new", start, end};
}

// Relocate the original server-rendered form, keeping native submission, CSRF,
// draft listeners, and a single set of IDs. Restore it when a diff is virtualized.
function InlineNativeContent({node, label, focus = false}: {node: HTMLDetailsElement; label?: string; focus?: boolean}) {
  const host = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    if (!host.current) return;
    const placeholder = document.createElement(label ? "a" : "span");
    if (placeholder instanceof HTMLAnchorElement) {
      placeholder.href = "#" + node.id;
      placeholder.textContent = label ?? "";
      placeholder.className = "inline-discussion-jump";
    }
    node.before(placeholder);
    host.current.append(node);
    if (focus) node.open = true;
    const actions = node.querySelectorAll<HTMLButtonElement>('[data-inline-cancel], [data-inline-discard]');
    actions.forEach(button => { button.hidden = false; });
    if (focus && node.hasAttribute('data-inline-focus')) {
      node.removeAttribute('data-inline-focus');
      node.querySelector<HTMLTextAreaElement>('textarea')?.focus({preventScroll:true});
    }
    return () => {
      actions.forEach(button => { button.hidden = true; });
      placeholder.replaceWith(node);
    };
  }, [node, label]);
  return <div ref={host} />;
}

// Native details, replies and textarea resizing happen outside React. Keep
// the virtualized diff's measured row heights in sync with those changes.
function InlineAnnotation({viewerRef, itemId, children}: {viewerRef: RefObject<CodeViewHandle<undefined, undefined> | null>; itemId: string; children: ReactNode}) {
  const host = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    if (!host.current) return;
    let frame = 0;
    const measure = () => {
      cancelAnimationFrame(frame);
      frame = requestAnimationFrame(() => {
        const viewer = viewerRef.current?.getInstance();
        const rendered = viewer?.getRenderedItems().find(item => item.id === itemId);
        if (rendered?.type === "diff" && rendered.instance.reconcileHeights()) {
          viewer?.instanceChanged(rendered.instance, true);
        }
      });
    };
    const observer = new ResizeObserver(measure);
    observer.observe(host.current);
    measure();
    return () => { observer.disconnect(); cancelAnimationFrame(frame); };
  }, [viewerRef, itemId]);
  return <div ref={host} className="inline-annotation">{children}</div>;
}

function renderCodeView(mount: HTMLElement, items: CodeViewItem<undefined>[], ready?: () => void, inline?: InlineReview): Root {
  ensureMoonhubCodeViewStyles();
  const root = createRoot(mount);
  root.render(
    <WorkerPoolContextProvider
      poolOptions={{
        workerFactory: () => new Worker(DiffWorkerUrl, { type: "module" }),
        poolSize: 2,
      }}
      highlighterOptions={{ preferredHighlighter: "shiki-js" }}
    >
      <MoonhubCodeView items={items} ready={ready} inline={inline} />
    </WorkerPoolContextProvider>,
  );
  return root;
}

function MoonhubCodeView({ items, ready, inline }: { items: CodeViewItem<undefined>[]; ready?: () => void; inline?: InlineReview }) {
  const [selection, setSelection] = useState<CodeViewLineSelection | null>(null);
  const selected = inlineLocation(items, selection);
  const [composer, setComposer] = useState<InlineLocation | null>(null);
  const [draftWarning, setDraftWarning] = useState("");
  const files = items.filter((item): item is CodeViewDiffItem<undefined> => item.type === "diff");
  const [mode, setMode] = useState<"split" | "unified">(() => matchMedia("(max-width: 900px)").matches ? "unified" : "split");
  const [wrap, setWrap] = useState(true);
  const [selectedFile, setSelectedFile] = useState(files[0]?.id ?? "");
  const manualMode = useRef(false);
  useEffect(() => { ready?.(); }, [ready]);
  useEffect(() => {
    const media = matchMedia("(max-width: 900px)");
    const sync = () => { if (!manualMode.current) setMode(media.matches ? "unified" : "split"); };
    media.addEventListener("change", sync); return () => media.removeEventListener("change", sync);
  }, []);
  const options = useMemo(() => ({
    ...codeViewOptions, enableLineSelection: Boolean(inline?.form),
    enableGutterUtility: Boolean(inline?.form), diffStyle: mode,
    overflow: wrap ? "wrap" as const : "scroll" as const,
  }), [mode, wrap, inline, items]);
  const viewerRef = useRef<CodeViewHandle<undefined, undefined> | null>(null);
  useEffect(() => {
    const thread = inline?.threads.find(thread => thread.id === inline.target);
    if (!thread) return;
    const item = items.find(item => item.type === "diff" && (thread.side === "old" ? item.fileDiff.prevName ?? item.fileDiff.name : item.fileDiff.name) === (thread.side === "old" ? thread.oldPath : thread.newPath));
    if (!item) return;
    const range = {start: thread.start, end: thread.end, side: thread.side === "old" ? "deletions" as const : "additions" as const};
    setSelection({id: item.id, range});
    updateDiffItem(item.id, diff => { diff.collapsed = false; return true; });
    const frame = requestAnimationFrame(() => viewerRef.current?.scrollTo({type: "range", id: item.id, range, align: "center"}));
    return () => cancelAnimationFrame(frame);
  }, [inline, items]);
  useEffect(() => {
    if (!inline) return;
    for (const initial of items) {
      const item = viewerRef.current?.getItem(initial.id);
      if (item?.type !== "diff") continue;
      const annotations = inline.threads.filter(thread => (thread.side === "old" ? item.fileDiff.prevName ?? item.fileDiff.name : item.fileDiff.name) === (thread.side === "old" ? thread.oldPath : thread.newPath)).map(thread => ({side: thread.side === "old" ? "deletions" as const : "additions" as const, lineNumber: thread.end}));
      for (const location of [selected, composer]) if (location?.id === item.id) annotations.push({side: location.side === "old" ? "deletions" : "additions", lineNumber: location.end});
      const unique = annotations.filter((annotation, index) => annotations.findIndex(other => other.side === annotation.side && other.lineNumber === annotation.lineNumber) === index);
      if (JSON.stringify(item.annotations) === JSON.stringify(unique)) continue;
      item.annotations = unique;
      item.version = getNextItemVersion(item);
      viewerRef.current?.updateItem(item);
    }
  }, [inline, items, selection, composer]);

  function openComposer(location: InlineLocation) {
    const details = inline?.form;
    const form = details?.querySelector<HTMLFormElement>('[data-inline-form]');
    if (!details || !form) return;
    const field = (name: string) => form.elements.namedItem(name) as HTMLInputElement | HTMLSelectElement | HTMLTextAreaElement;
    const previousItem = items.find(item => item.type === "diff" && (field("side").value === "old" ? item.fileDiff.prevName ?? item.fileDiff.name : item.fileDiff.name) === field("path").value);
    const previous = previousItem && inlineLocation(items, {id: previousItem.id, range: {side: field("side").value === "old" ? "deletions" : "additions", start: Number(field("start_line").value), end: Number(field("end_line").value)}});
    if (field("body").value.trim() && previous) {
      setDraftWarning(JSON.stringify(previous) === JSON.stringify(location) ? "" : "Your draft belongs to these lines. Send it, or discard it before commenting elsewhere.");
      location = previous;
    } else {
      setDraftWarning("");
      for (const [name, value] of Object.entries({path: location.path, side: location.side, start_line: String(location.start), end_line: String(location.end)})) field(name).value = value;
      form.dispatchEvent(new Event('input', {bubbles:true}));
    }
    details.open = true;
    details.setAttribute('data-inline-focus', '');
    setComposer({...location});
    setSelection({id: location.id, range: {start: location.start, end: location.end, side: location.side === "old" ? "deletions" : "additions"}});
    updateDiffItem(location.id, item => { item.collapsed = false; return true; });
    requestAnimationFrame(() => {
      viewerRef.current?.scrollTo({type: "range", id: location.id, range: {start: location.end, end: location.end, side: location.side === "old" ? "deletions" : "additions"}, align: "center"});
      form.querySelector('textarea')?.focus({preventScroll:true});
    });
  }

  function closeComposer(discard = false) {
    if (discard) {
      const body = inline?.form?.querySelector<HTMLTextAreaElement>('textarea');
      if (body) { body.value = ""; body.dispatchEvent(new Event('input', {bubbles:true})); }
    }
    if (inline?.form) inline.form.open = false;
    setComposer(null);
    setDraftWarning("");
    requestAnimationFrame(() => document.querySelector<HTMLButtonElement>('.inline-selection-action button')?.focus({preventScroll:true}));
  }

  const anyLargeDiffs = useMemo(
    () =>
      items.some(
        (item) =>
          item.type === "diff" &&
          getPatchLineCount(item.fileDiff) > largeDiffLineThreshold,
      ),
    [items],
  );

  function updateDiffItem(
    itemId: string,
    updateItem: (item: CodeViewDiffItem) => boolean,
  ) {
    const viewerHandle = viewerRef.current;
    const viewer = viewerHandle?.getInstance();
    const item = viewerHandle?.getItem(itemId);
    if (viewerHandle == null || viewer == null || item?.type !== "diff") {
      return;
    }

    const itemTop = viewer.getTopForItem(itemId);
    if (!updateItem(item)) {
      return;
    }

    item.version = getNextItemVersion(item);
    if (!viewerHandle.updateItem(item)) {
      return;
    }

    if (itemTop != null && itemTop < viewer.getScrollTop()) {
      viewer.scrollTo({
        type: "item",
        id: item.id,
        align: "start",
      });
    }
  }

  function expandLargeDiffs() {
    const viewerHandle = viewerRef.current;
    if (viewerHandle == null) {
      return;
    }

    for (const initialItem of items) {
      if (
        initialItem.type !== "diff" ||
        getPatchLineCount(initialItem.fileDiff) <= largeDiffLineThreshold
      ) {
        continue;
      }

      const item = viewerHandle.getItem(initialItem.id);
      if (item?.type !== "diff" || item.collapsed !== true) {
        continue;
      }

      item.collapsed = false;
      item.version = getNextItemVersion(item);
      viewerHandle.updateItem(item);
    }
  }

  return (
    <div className={files.length ? "moonhub-code-view-frame diff-workspace" : "moonhub-code-view-frame"} style={codeViewShellStyle}>
      <div className="diff-controls">
        {files.length > 0 && <><strong>{files.length} changed files</strong><label>View <select aria-label="Diff view" value={mode} onChange={event => { manualMode.current = true; setMode(event.target.value as "split" | "unified"); }}><option value="split">Split</option><option value="unified">Unified</option></select></label></>}
        <label className="checkbox-field"><input type="checkbox" checked={wrap} onChange={event => setWrap(event.target.checked)} />Wrap lines</label>
      </div>
      {files.length > 0 && <nav className="diff-file-nav" aria-label="Changed files">{files.map(item => <button type="button" key={item.id} aria-current={selectedFile === item.id ? "true" : undefined} onClick={() => {
        updateDiffItem(item.id, diff => { diff.collapsed = false; return true; });
        setSelectedFile(item.id); viewerRef.current?.scrollTo({ type: "item", id: item.id, align: "start" });
      }}>{item.fileDiff.name ?? item.fileDiff.prevName ?? "File"}</button>)}</nav>}
      <div className="diff-canvas">
      {inline?.form && <p className="inline-line-hint">Use the + beside a line to comment. Select or Shift-click line numbers for a range.{selection && !selected && <span role="status"> Choose up to 100 displayed lines on one side of a hunk.</span>}</p>}
      {anyLargeDiffs ? (
        <div className="moonhub-code-view-toolbar">
          <span>Large diffs are collapsed by default.</span>
          <button type="button" onClick={expandLargeDiffs}>
            Expand all
          </button>
        </div>
      ) : null}
      <CodeView
        ref={viewerRef}
        selectedLines={selection}
        onSelectedLinesChange={setSelection}
        renderAnnotation={(annotation, item) => {
          if (!inline || item.type !== "diff" || !("side" in annotation)) return null;
          const side = annotation.side === "deletions" ? "old" : "new";
          const path = side === "old" ? item.fileDiff.prevName ?? item.fileDiff.name : item.fileDiff.name;
          const threads = inline.threads.filter(thread => thread.side === side && thread.end === annotation.lineNumber && path === (side === "old" ? thread.oldPath : thread.newPath));
          const editing = composer?.id === item.id && composer.side === side && composer.end === annotation.lineNumber;
          const action = inline.form && selected?.id === item.id && selected.side === side && selected.end === annotation.lineNumber && !editing;
          return <InlineAnnotation viewerRef={viewerRef} itemId={item.id}>
            {threads.map(thread => thread.node ? <div className="inline-discussion-slot" key={thread.id}><InlineNativeContent node={thread.node} label={thread.label + " · " + path + " · " + side + " L" + thread.start + "–" + thread.end} /></div> : <a className="inline-thread-link" key={thread.id} href={thread.href}>{thread.label}<span>{thread.preview}</span></a>)}
            {editing && inline.form && <section className="inline-editor" aria-label="New code discussion" onClick={event => {
              const button = (event.target as HTMLElement).closest('button');
              if (button?.hasAttribute('data-inline-cancel')) closeComposer();
              if (button?.hasAttribute('data-inline-discard')) closeComposer(true);
            }} onKeyDown={event => {
              if (event.key === "Escape") { event.preventDefault(); closeComposer(); }
              if (event.key === "Enter" && (event.metaKey || event.ctrlKey)) { event.preventDefault(); inline.form?.querySelector('form')?.requestSubmit(); }
            }}>
              <header><strong>New discussion</strong><span>{composer.path} · {composer.side} L{composer.start}–{composer.end}</span></header>
              {draftWarning && <p className="inline-draft-warning" role="status">{draftWarning}</p>}
              <InlineNativeContent node={inline.form} focus />
            </section>}
            {action && <div className="inline-selection-action"><span>{side} L{selected.start}–{selected.end}</span><button type="button" onClick={() => openComposer(selected)}>Comment on selected lines</button></div>}
          </InlineAnnotation>;
        }}
        initialItems={items}
        className={inline && files.reduce((count, item) => count + getPatchLineCount(item.fileDiff), 0) <= largeDiffLineThreshold ? "moonhub-code-view inline-review-content" : "moonhub-code-view"}
        renderGutterUtility={inline?.form ? (getHoveredLine, item) => <button type="button" className="moonhub-comment-line-button" aria-label="Comment on selected lines" title="Comment on this line or selection" onPointerDown={event => event.stopPropagation()} onClick={() => {
          const hovered = getHoveredLine();
          if (!hovered) return;
          const side = "side" in hovered && hovered.side === "deletions" ? "deletions" : "additions";
          const line = inlineLocation(items, {id: item.id, range: {start: hovered.lineNumber, end: hovered.lineNumber, side}});
          const range = inlineLocation(items, viewerRef.current?.getSelectedLines() ?? null);
          const location = line && range?.id === line.id && range.side === line.side && line.start >= range.start && line.end <= range.end ? range : line;
          if (location) openComposer(location);
        }}><span className="ui-icon" data-icon="plus" aria-hidden="true" /></button> : undefined}
        options={options}
        renderHeaderPrefix={(item) =>
          item.type === "diff" ? (
            <CollapseDiffButton
              collapsed={item.collapsed === true}
              disabled={getPatchLineCount(item.fileDiff) === 0}
              onToggle={() => {
                updateDiffItem(item.id, (diffItem) => {
                  diffItem.collapsed = diffItem.collapsed !== true;
                  return true;
                });
              }}
            />
          ) : null
        }
      />
      </div>
    </div>
  );
}

function CollapseDiffButton({
  collapsed,
  disabled,
  onToggle,
}: {
  collapsed: boolean;
  disabled: boolean;
  onToggle(): void;
}) {
  return (
    <button
      type="button"
      className="moonhub-collapse-diff-button"
      data-collapsed={collapsed ? "true" : "false"}
      disabled={disabled}
      aria-expanded={!disabled && !collapsed}
      aria-hidden={disabled}
      aria-label={
        disabled ? undefined : collapsed ? "Expand diff" : "Collapse diff"
      }
      title={disabled ? undefined : collapsed ? "Expand diff" : "Collapse diff"}
      onClick={(event) => {
        event.preventDefault();
        event.stopPropagation();
        onToggle();
      }}
    >
      <span aria-hidden="true" />
    </button>
  );
}

function ensureMoonhubCodeViewStyles() {
  if (document.getElementById("moonhub-code-view-styles") != null) {
    return;
  }

  const style = document.createElement("style");
  style.id = "moonhub-code-view-styles";
  style.textContent = moonhubCodeViewStyles;
  document.head.append(style);
}

function getNextItemVersion(item: CodeViewItem<undefined>): number {
  return typeof item.version === "number" ? item.version + 1 : 1;
}

function getPatchLineCount(fileDiff: FileDiffMetadata): number {
  return fileDiff.hunks.reduce(
    (lineCount, hunk) => lineCount + hunk.unifiedLineCount,
    0,
  );
}

function moonBitLanguageForPath(name: string | undefined): MoonBitLanguage | undefined {
  return name?.endsWith(".mbt") || name?.endsWith(".mbti")
    ? "moonbit"
    : undefined;
}

function moonBitLanguageForDiff(
  fileDiff: FileDiffMetadata,
): MoonBitLanguage | undefined {
  return (
    moonBitLanguageForPath(fileDiff.name) ??
    moonBitLanguageForPath(fileDiff.prevName)
  );
}

// Recover exact Git paths: the diff parser strips quotes without decoding C escapes.
function gitPatchPath(raw: string): string {
  if (!raw.startsWith('"')) return raw.replace(/\t$/, "");
  const encoded = raw.match(/^"((?:[^"\\]|\\.)*)"/)?.[1];
  if (encoded == null) return raw;
  const bytes: number[] = [];
  const escapes: Record<string, number> = {a: 7, b: 8, t: 9, n: 10, v: 11, f: 12, r: 13};
  for (let i = 0; i < encoded.length;) {
    if (encoded[i] === "\\") {
      const octal = encoded.slice(i + 1).match(/^[0-7]{1,3}/)?.[0];
      if (octal) { bytes.push(parseInt(octal, 8)); i += octal.length + 1; continue; }
      const escaped = encoded[++i];
      bytes.push(escapes[escaped] ?? escaped.charCodeAt(0)); i++;
    } else {
      const ch = String.fromCodePoint(encoded.codePointAt(i)!);
      bytes.push(...new TextEncoder().encode(ch)); i += ch.length;
    }
  }
  return new TextDecoder().decode(new Uint8Array(bytes));
}

function patchToItems(patch: string): CodeViewItem<undefined>[] {
  const headers = patch.split(/(?=^diff --git )/m).filter(part => part.startsWith("diff --git ")).map(part => part.split("\n@@ ")[0].split("\n"));
  let fileNumber = 0;
  return parsePatchFiles(patch, "moonhub", true).flatMap(
    (parsedPatch, patchIndex) =>
      parsedPatch.files.map((fileDiff, fileIndex) => {
        const header = headers[fileNumber++];
        if (header) {
          const path = (prefix: string, stripPrefix: boolean) => {
            const line = header.find(line => line.startsWith(prefix));
            if (!line) return undefined;
            const value = gitPatchPath(line.slice(prefix.length));
            return value === "/dev/null" ? undefined : stripPrefix ? value.replace(/^[ab]\//, "") : value;
          };
          const previous = path("rename from ", false) ?? path("--- ", true);
          const current = path("rename to ", false) ?? path("+++ ", true);
          if (current ?? previous) fileDiff.name = current ?? previous!;
          if (previous && current && previous !== current) fileDiff.prevName = previous;
        }
        const lang = moonBitLanguageForDiff(fileDiff);
        return {
          id: `patch-${patchIndex}-file-${fileIndex}`,
          type: "diff",
          fileDiff: lang == null ? fileDiff : { ...fileDiff, lang },
          version: 0,
          collapsed: getPatchLineCount(fileDiff) > largeDiffLineThreshold,
        };
      }),
  );
}

function fileToItems(name: string, contents: string): CodeViewItem<undefined>[] {
  const lang = moonBitLanguageForPath(name);
  return [
    {
      id: "file",
      type: "file",
      file: {
        name,
        contents,
        cacheKey: `${name}:${contents.length}`,
        ...(lang == null ? undefined : { lang }),
      },
      version: 0,
    },
  ];
}

class MoonhubCommitDiffElement extends HTMLElement {
  #root: Root | undefined;

  connectedCallback() {
    if (this.#root) {
      return;
    }

    const fallback = this.querySelector<HTMLPreElement>("pre[data-patch]");
    const patch = fallback?.textContent ?? "";
    if (patch.length === 0) {
      return;
    }

    const mount = document.createElement("div");
    mount.className = "moonhub-commit-diff";
    this.append(mount);
    try {
      const items = patchToItems(patch);
      let inline: InlineReview | undefined;
      if (this.hasAttribute("data-inline-review")) {
        const threads: InlineThread[] = [...this.querySelectorAll<HTMLAnchorElement>('[data-inline-thread]')].map(link => ({id: link.dataset.discussion ?? "", oldPath: link.dataset.oldPath ?? "", newPath: link.dataset.newPath ?? "", side: link.dataset.side === "old" ? "old" : "new", start: Number(link.dataset.start), end: Number(link.dataset.end), href: link.href, label: link.textContent ?? "Discussion", preview: link.dataset.preview ?? "", node: document.getElementById("discussion-" + link.dataset.discussion) as HTMLDetailsElement | null}));
        for (const item of items) if (item.type === "diff") {
          item.annotations = threads.filter(t => (t.side === "old" ? item.fileDiff.prevName ?? item.fileDiff.name : item.fileDiff.name) === (t.side === "old" ? t.oldPath : t.newPath)).filter((t, i, all) => all.findIndex(other => other.side === t.side && other.end === t.end) === i).map(t => ({side: t.side === "old" ? "deletions" as const : "additions" as const, lineNumber: t.end}));
        }
        const url = new URL(location.href);
        inline = {threads, target: url.searchParams.get("code") ?? url.searchParams.get("discussion") ?? undefined, form: document.querySelector<HTMLDetailsElement>('#inline-composer')};
      }
      const loading = document.createElement("p"); loading.className = "diff-loading"; loading.setAttribute("role", "status"); loading.textContent = "Preparing file changes…";
      mount.before(loading);
      this.#root = renderCodeView(mount, items, () => { loading.remove(); if (fallback) fallback.hidden = true; }, inline);
    } catch (error) {
      mount.remove();
      console.error("moonhub commit diff failed to render", error);
    }
  }

  disconnectedCallback() {
    this.#root?.unmount();
    this.#root = undefined;
  }
}

class MoonhubFileViewElement extends HTMLElement {
  #root: Root | undefined;

  connectedCallback() {
    if (this.#root) {
      return;
    }

    const name =
      this.querySelector<HTMLElement>("[data-file-name]")?.textContent ??
      "file";
    const fallback = this.querySelector<HTMLPreElement>(
      "pre[data-file-content]",
    );
    if (!fallback) {
      return;
    }

    const mount = document.createElement("div");
    mount.className = "moonhub-file-view";
    this.append(mount);
    try {
      const items = fileToItems(name, fallback.textContent ?? "");
      this.#root = renderCodeView(mount, items);
      fallback.hidden = true;
    } catch (error) {
      mount.remove();
      console.error("moonhub file view failed to render", error);
    }
  }

  disconnectedCallback() {
    this.#root?.unmount();
    this.#root = undefined;
  }
}

if (!customElements.get("moonhub-commit-diff")) {
  customElements.define("moonhub-commit-diff", MoonhubCommitDiffElement);
}

if (!customElements.get("moonhub-file-view")) {
  customElements.define("moonhub-file-view", MoonhubFileViewElement);
}
