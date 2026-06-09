import {
  type CodeViewDiffItem,
  parsePatchFiles,
  setCustomExtension,
  type CodeViewLayout,
  type CodeViewItem,
  type FileDiffMetadata,
} from "@pierre/diffs";
import {
  CodeView,
  type CodeViewHandle,
  WorkerPoolContextProvider,
} from "@pierre/diffs/react";
import { type CSSProperties, useMemo, useRef } from "react";
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
  "--moonhub-diff-border": "#d8dee4",
  "--moonhub-diff-muted": "#57606a",
  "--moonhub-diff-hover-bg": "#f6f8fa",
  "--diffs-font-family":
    "\"M PLUS Code Latin\", \"SF Mono\", Monaco, Consolas, \"Ubuntu Mono\", \"Liberation Mono\", \"Courier New\", monospace",
  "--diffs-font-size": "13px",
} as CSSProperties;

const moonhubCodeViewStyles = `
.moonhub-code-view-frame {
  overflow: hidden;
  min-width: 0;
  border: 1px solid var(--moonhub-diff-border);
  border-radius: 8px;
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

function renderCodeView(mount: HTMLElement, items: CodeViewItem[]): Root {
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
      <MoonhubCodeView items={items} />
    </WorkerPoolContextProvider>,
  );
  return root;
}

function MoonhubCodeView({ items }: { items: CodeViewItem[] }) {
  const viewerRef = useRef<CodeViewHandle<undefined> | null>(null);
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
    <div className="moonhub-code-view-frame" style={codeViewShellStyle}>
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
        initialItems={items}
        className="moonhub-code-view"
        options={codeViewOptions}
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

function getNextItemVersion(item: CodeViewItem): number {
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

function patchToItems(patch: string): CodeViewItem[] {
  return parsePatchFiles(patch, "moonhub", true).flatMap(
    (parsedPatch, patchIndex) =>
      parsedPatch.files.map((fileDiff, fileIndex) => {
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

function fileToItems(name: string, contents: string): CodeViewItem[] {
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
      this.#root = renderCodeView(mount, items);
      if (fallback) {
        fallback.hidden = true;
      }
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
