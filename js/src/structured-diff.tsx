import { createPortal } from "react-dom";
import { createRoot, type Root } from "react-dom/client";
import { useEffect, useLayoutEffect, useRef, useState, type ReactNode } from "react";
import { getFiletypeFromFileName, getResolvedOrResolveLanguage } from "@pierre/diffs";
import HighlightWorker from "./diff-highlight.worker?worker";

type Options = { mode: "lexical" | "ast" | "line"; ignore_comments: boolean; ignore_tests: boolean };
type File = { id: string; status: string; old_path: string; new_path: string; old_mode: string; new_mode: string; path_error?: string | null };
type Manifest = { protocol: string; comparison_id: string; page: number; has_more: boolean; base_sha: string; head_sha: string; files: File[] };
type Line = { number: number; segments: { kind: string; text: string }[] };
type Row = { kind: string; old?: Line; new?: Line };
type Hunk = { id: string; rows: Row[] };
type Section = { id: string; kind: string; old_context?: string; new_context?: string; hunks: Hunk[]; fallbacks: string[] };
type FileResult = { document_id: string; file: File; options: Options; error?: string | null; document?: { status: string; ignore_reason?: string; reordered: boolean; old_order: number[]; new_order: number[]; old_eol: string; new_eol: string; old_final_newline?: boolean; new_final_newline?: boolean; sections: Section[] } | null };
type Token = { content: string; color?: string };

function optionsURL(base: string, options: Options) {
  const url = new URL(base, location.href);
  for (const [key, value] of Object.entries(options)) url.searchParams.set(key, String(value));
  return url;
}

// A single generation owns all its requests and highlight worker. Disposing it
// cancels in-flight fetches, queued work and responses from the previous mode.
class Loader {
  controller = new AbortController();
  worker = new HighlightWorker();
  active = 0;
  queue: (() => void)[] = [];
  highlightId = 0;
  pending = new Map<number, (tokens: Token[][]) => void>();
  constructor(public endpoint: string, public manifest: Manifest, public options: Options) {
    this.worker.onmessage = ({ data }: MessageEvent<{ id: number; tokens: Token[][] }>) => {
      this.pending.get(data.id)?.(data.tokens); this.pending.delete(data.id);
    };
  }
  dispose() {
    this.controller.abort(); this.queue.splice(0).forEach(next => next());
    this.worker.terminate(); this.pending.forEach(resolve => resolve([])); this.pending.clear();
  }
  async file(id: string): Promise<FileResult> {
    if (this.active >= 2) await new Promise<void>(resolve => this.queue.push(resolve));
    this.controller.signal.throwIfAborted();
    this.active++;
    try {
      const url = new URL(this.endpoint, location.href);
      url.searchParams.set("file_id", id); url.searchParams.set("page", String(this.manifest.page));
      for (const [key, value] of Object.entries(this.options)) url.searchParams.set(key, String(value));
      const response = await fetch(url, { signal: this.controller.signal, cache: "no-store", headers: { Accept: "application/json" } });
      if (!response.ok) throw new Error("Unable to load this file. Retry or select Line mode.");
      const result: FileResult & { comparison_id: string; protocol: string } = await response.json();
      if (result.protocol !== "moonhub-diff/1" || result.comparison_id !== this.manifest.comparison_id || result.file.id !== id) throw new Error("Comparison changed. Refresh this page.");
      return result;
    } finally { this.active--; this.queue.shift()?.(); }
  }
  highlight(text: string, path: string): Promise<Token[][]> {
    if (this.controller.signal.aborted) return Promise.resolve([]);
    const id = ++this.highlightId;
    return new Promise(resolve => {
      // Disposal must also settle requests still waiting for a grammar import.
      this.pending.set(id, resolve);
      void (async () => {
        try {
          const lang = /\.mbti?$/.test(path) ? "moonbit" : getFiletypeFromFileName(path);
          const grammar = lang === "text" || lang === "ansi" || lang === "moonbit"
            ? undefined : await getResolvedOrResolveLanguage(lang);
          if (!this.controller.signal.aborted) this.worker.postMessage({ id, text, lang, grammar: grammar?.data });
        } catch {
          this.pending.get(id)?.([]); this.pending.delete(id);
        }
      })();
    });
  }
}

function LineContent({ line, tokens }: { line: Line; tokens?: Token[] }) {
  // Intersect syntax tokens with the backend's intraline segments. Highlighting
  // only supplies color; the server alone determines changed/ignored spans.
  let offset = 0;
  const syntax = (tokens ?? []).map(token => { const start = offset; offset += token.content.length; return { ...token, start, end: offset }; });
  offset = 0;
  return <code>{line.segments.map((segment, index) => {
    const start = offset; offset += segment.text.length;
    const spans = syntax.filter(token => token.end > start && token.start < offset).map((token, i) => <span key={i} style={{ color: token.color }}>{segment.text.slice(Math.max(0, token.start - start), Math.min(segment.text.length, token.end - start))}</span>);
    return <span className={`segment-${segment.kind}`} key={index}>{spans.length ? spans : segment.text}</span>;
  })}</code>;
}

type Thread = { id: string; path: string; side: "old" | "new"; start: number; end: number; context: string };

type Selection = { document: string; file: string; hunk: string; side: "old" | "new"; start: number; end: number };

// Keep the four-column tables (and spanning editor rows) intact. Only code is
// translated; one native scrollbar owns the offset for each side of this block.
function SplitScrollBlock({ children, enabled, label }: { children: ReactNode; enabled: boolean; label: string }) {
  const block = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    const node = block.current!;
    const sides = ["old", "new"] as const;
    const bars = sides.map(side => node.querySelector<HTMLDivElement>(`.structured-scrollbar.${side}`)!);
    const sync = (index: number) => node.style.setProperty(`--split-${sides[index]}-offset`, `${-bars[index].scrollLeft}px`);
    let frame = 0;
    const measure = () => {
      frame = 0;
      // A closed declaration/file has no measurable code. Preserve its offset
      // until it opens again rather than clamping it against a zero width.
      const widths = sides.map(side => {
        const cells = [...node.querySelectorAll<HTMLElement>(`.diff-source.${side} > div`)];
        return { viewport: cells[0]?.clientWidth ?? 0, content: Math.max(0, ...cells.map(cell => cell.querySelector("code")?.scrollWidth ?? 0)) };
      });
      widths.forEach(({ viewport, content }, index) => {
        if (!viewport) return;
        const bar = bars[index];
        bar.hidden = !enabled || content <= viewport;
        (bar.firstElementChild as HTMLElement).style.width = `${content}px`;
        bar.scrollLeft = enabled ? Math.min(bar.scrollLeft, Math.max(0, content - viewport)) : 0;
        sync(index);
      });
    };
    const schedule = () => { if (!frame) frame = requestAnimationFrame(measure); };
    const observer = new ResizeObserver(schedule);
    observer.observe(node);
    node.querySelectorAll(".diff-source > div, .diff-source code").forEach(line => observer.observe(line));
    const ancestors: HTMLDetailsElement[] = [];
    for (let parent = node.parentElement; parent; parent = parent.parentElement) if (parent instanceof HTMLDetailsElement) {
      ancestors.push(parent); parent.addEventListener("toggle", schedule);
    }
    const sideAt = (target: EventTarget | null) => {
      const cell = target instanceof Element ? target.closest(".diff-source") : null;
      return cell && node.contains(cell) ? cell.classList.contains("old") ? 0 : 1 : -1;
    };
    const wheel = (event: WheelEvent) => {
      const index = sideAt(event.target);
      if (!enabled || event.ctrlKey || index < 0 || bars[index].hidden) return;
      if (!event.shiftKey && Math.abs(event.deltaY) > Math.abs(event.deltaX)) return;
      const delta = event.shiftKey && !event.deltaX ? event.deltaY : event.deltaX;
      if (!delta) return;
      event.preventDefault();
      bars[index].scrollLeft += delta * (event.deltaMode === 1 ? 20 : event.deltaMode === 2 ? bars[index].clientWidth : 1);
      sync(index);
    };
    let touch: { index: number; x: number; y: number; offset: number; axis?: "x" | "y" } | undefined;
    const touchStart = (event: TouchEvent) => {
      touch = undefined;
      const index = sideAt(event.target);
      if (enabled && event.touches.length === 1 && index >= 0 && !bars[index].hidden) {
        touch = { index, x: event.touches[0].clientX, y: event.touches[0].clientY, offset: bars[index].scrollLeft };
      }
    };
    const touchMove = (event: TouchEvent) => {
      if (!touch || event.touches.length !== 1) return;
      const dx = touch.x - event.touches[0].clientX, dy = touch.y - event.touches[0].clientY;
      if (!touch.axis && Math.max(Math.abs(dx), Math.abs(dy)) > 6) touch.axis = Math.abs(dx) > Math.abs(dy) ? "x" : "y";
      if (touch.axis !== "x") return;
      event.preventDefault();
      bars[touch.index].scrollLeft = touch.offset + dx;
      sync(touch.index);
    };
    const touchEnd = () => { touch = undefined; };
    node.addEventListener("wheel", wheel, { passive: false });
    node.addEventListener("touchstart", touchStart, { passive: true });
    node.addEventListener("touchmove", touchMove, { passive: false });
    node.addEventListener("touchend", touchEnd);
    node.addEventListener("touchcancel", touchEnd);
    if (!enabled) bars.forEach((bar, index) => { bar.scrollLeft = 0; sync(index); });
    measure();
    return () => {
      observer.disconnect(); cancelAnimationFrame(frame);
      ancestors.forEach(parent => parent.removeEventListener("toggle", schedule));
      node.removeEventListener("wheel", wheel);
      node.removeEventListener("touchstart", touchStart);
      node.removeEventListener("touchmove", touchMove);
      node.removeEventListener("touchend", touchEnd);
      node.removeEventListener("touchcancel", touchEnd);
    };
  }, [enabled, children]);
  return <div ref={block} className={`structured-scroll-block${enabled ? " unwrapped" : ""}`}>
    {children}
    <div className="structured-scrollbars">
      {(["old", "new"] as const).map(side => <div key={side} hidden className={`structured-scrollbar ${side}`} tabIndex={0} role="region" aria-label={`${label}: ${side === "old" ? "Old" : "New"} code horizontal scroll`} onScroll={event => block.current?.style.setProperty(`--split-${side}-offset`, `${-event.currentTarget.scrollLeft}px`)}><div /></div>)}
    </div>
  </div>;
}

// Keep the server form and its editor, upload and draft listeners alive while
// placing it beside the selected code. Restore it before React removes the row.
function InlineComposer({ node, selection, path, notice }: { node: HTMLDetailsElement; selection: Selection; path: string; notice: string }) {
  const mount = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    const placeholder = document.createElement("span");
    node.before(placeholder);
    mount.current!.append(node);
    node.open = true;
    return () => { placeholder.replaceWith(node); };
  }, [node]);
  useLayoutEffect(() => {
    const button = mount.current?.closest("tr")?.previousElementSibling?.querySelector<HTMLElement>(`[data-source-side="${selection.side}"][data-source-line="${Math.max(selection.start, selection.end)}"]`);
    button?.scrollIntoView({ block: "center" });
    const body = node.querySelector<HTMLTextAreaElement>('textarea[name=body]');
    if (body && body.dispatchEvent(new Event("markdown-focus", { cancelable: true }))) body.focus({ preventScroll: true });
  }, [node, selection]);
  return <section className="structured-inline-composer inline-editor inline-annotation" aria-label="New code discussion">
    <header><strong>New discussion</strong><span>{path} · {selection.side} L{Math.min(selection.start, selection.end)}–{Math.max(selection.start, selection.end)}</span></header>
    <p role="status">{notice}</p>
    <div ref={mount} />
  </section>;
}

function FileView({ file, loader, initial, unified, wrap, select, threads, selection, composer, notice }: { selection?: Selection; composer?: HTMLDetailsElement; notice: string; threads: Thread[]; file: File; loader: Loader; initial?: FileResult; unified: boolean; wrap: boolean; select: (result: FileResult, hunk: Hunk, side: "old" | "new", line: number, extend: boolean) => void }) {
  const [result, setResult] = useState<FileResult | undefined>(initial);
  const [error, setError] = useState("");
  const [visible, setVisible] = useState(() => {
    const target = new URL(location.href).searchParams.get("code");
    return threads.some(thread => thread.id === `discussion-${target}` && thread.path === (thread.side === "old" ? file.old_path : file.new_path));
  });
  const [open, setOpen] = useState(true);
  const [attempt, setAttempt] = useState(0);
  const [colors, setColors] = useState<Map<string, Token[]>>(new Map());
  const details = useRef<HTMLDetailsElement>(null);
  useEffect(() => {
    const observer = new IntersectionObserver(entries => { if (entries.some(entry => entry.isIntersecting)) { setVisible(true); observer.disconnect(); } }, { rootMargin: "200px" });
    if (details.current) observer.observe(details.current);
    return () => observer.disconnect();
  }, []);
  useEffect(() => {
    if (file.path_error || !visible || !open || result) return;
    let current = true;
    loader.file(file.id).then(data => { if (current) { setResult(data); setError(""); } }).catch(error => { if (current && !loader.controller.signal.aborted) setError(String(error.message)); });
    return () => { current = false; };
  }, [visible, open, file.id, loader, attempt, result]);
  useEffect(() => {
    if (!result?.document) return;
    let current = true;
    const lines = result.document.sections.flatMap(s => s.hunks.flatMap(h => h.rows.flatMap(r => [r.old, r.new].filter((l): l is Line => !!l))));
    loader.highlight(lines.map(l => l.segments.map(s => s.text).join("")).join("\n"), file.new_path || file.old_path).then(tokens => {
      if (current) setColors(new Map(lines.map((line, i) => [line.segments.map(s => s.text).join(""), tokens[i] ?? []])));
    });
    return () => { current = false; };
  }, [result, loader, file]);
  useEffect(() => {
    const targetId = new URL(location.href).searchParams.get("code");
    const thread = threads.find(t => t.id === `discussion-${targetId}` && t.path === (t.side === "old" ? file.old_path : file.new_path));
    if (!result?.document || !thread) return;
    const button = details.current?.querySelector<HTMLElement>(`[data-source-side="${thread.side}"][data-source-line="${thread.end}"]`);
    if (!button) { details.current?.scrollIntoView({ block: "center" }); return; }
    for (let parent = button.parentElement; parent; parent = parent.parentElement) if (parent instanceof HTMLDetailsElement) parent.open = true;
    button.scrollIntoView({ block: "center" });
  }, [result, threads, file]);
  const doc = result?.document;
  const fileSide = file.status === "A" ? "new" : file.status === "D" ? "old" : undefined;
  const retry = () => { setResult(undefined); setError(""); setAttempt(a => a + 1); };
  return <details ref={details} open={open} onToggle={event => setOpen(event.currentTarget.open)} className="structured-file" id={`diff-file-${file.id}`}>
    <summary>{fileSide ? file.new_path || file.old_path : <>{file.status} · {file.old_path !== file.new_path ? `${file.old_path || "∅"} → ${file.new_path || "∅"}` : file.new_path}{file.old_mode !== file.new_mode && <small> · Mode: {file.old_mode || "∅"} → {file.new_mode || "∅"}</small>}</>}</summary>
    {!file.path_error && !result && !error && <p role="status">{visible && open ? "Loading changes…" : "Expand to load changes"}</p>}
    {(file.path_error || error || result?.error) && <p role="alert">{file.path_error || error || result?.error} {!file.path_error && <button onClick={retry}>Retry file</button>}</p>}
    {threads.filter(t => !file.path_error && t.path === (t.side === "old" ? file.old_path : file.new_path)).map(thread => <div key={thread.id}><a href={`#${thread.id}`}>Discussion: {thread.side} L{thread.start}–{thread.end}</a>{doc && !doc.sections.some(s => s.hunks.some(h => h.rows.some(r => r[thread.side]?.number === thread.start))) && <div> · Location hidden in this view. <a href={(() => { const url = new URL(location.href); url.searchParams.set("mode", "line"); url.searchParams.set("ignore_comments", "false"); url.searchParams.set("ignore_tests", "false"); return url.href; })()}>Show original position</a><pre>{thread.context}</pre></div>}</div>)}
    {doc && <>
      {!fileSide && <p className="structured-metadata">{doc.status} · {result.options.mode}</p>}
      {doc.ignore_reason && <p>Filtered: {doc.ignore_reason}. Disable filters to see original content.</p>}
      {!fileSide && doc.old_eol !== doc.new_eol && <p>Line endings: {doc.old_eol} → {doc.new_eol}.</p>}
      {!fileSide && doc.old_final_newline !== doc.new_final_newline && <p>Final newline: {String(doc.old_final_newline ?? "absent")} → {String(doc.new_final_newline ?? "absent")}.</p>}
      {!fileSide && doc.reordered && <p>Declaration order changed: {doc.old_order.join(" → ")} to {doc.new_order.join(" → ")}</p>}
      {doc.sections.filter(section => section.hunks.length > 0 || section.fallbacks.length > 0).map(section => {
        const side = fileSide ?? (section.kind === "inserted" ? "new" : section.kind === "deleted" ? "old" : undefined);
        const renderHunk = (hunk: Hunk) => <div key={hunk.id} className="structured-hunk" data-hunk={hunk.id} data-change tabIndex={-1}>
          <table className={side ? `single-side ${side}` : unified ? "unified" : "split"}><tbody>{hunk.rows.flatMap((row, index) => {
            const selected = (side: "old" | "new", line?: Line) => !!line && selection?.document === result.document_id && selection.file === file.id && selection.hunk === hunk.id && selection.side === side && line.number >= Math.min(selection.start, selection.end) && line.number <= Math.max(selection.start, selection.end);
            const lineNumber = (side: "old" | "new", line?: Line) => <td className={`line-number${selected(side, line) ? " is-selected" : ""}`}>{line && <button data-source-side={side} data-source-line={line.number} aria-pressed={selected(side, line)} aria-label={`${side} line ${line.number}`} onClick={event => select(result, hunk, side, line.number, event.shiftKey)}>{line.number}</button>}</td>;
            const source = (side: "old" | "new", line?: Line, shared = false) => <td className={`diff-source ${row.kind} ${side}${selected(side, line) || shared && selected("old", row.old) ? " is-selected" : ""}`}><div>{line && <LineContent line={line} tokens={colors.get(line.segments.map(s => s.text).join(""))} />}</div></td>;
            const rows = (() => {
              if (side) return row[side] ? [<tr key={index}>{lineNumber(side, row[side])}{source(side, row[side])}</tr>] : [];
              if (unified) {
                // Ignoring comments also marks identical separators as ignored.
                const unchanged = row.kind === "context" || row.kind === "ignored" && row.old?.segments.map(s => s.text).join("") === row.new?.segments.map(s => s.text).join("");
                if (unchanged && row.old && row.new) return [<tr key={index}>{lineNumber("old", row.old)}{lineNumber("new", row.new)}{source("new", row.new, true)}</tr>];
                return (["old", "new"] as const).flatMap(side => row[side] ? [<tr key={`${index}-${side}`}>{lineNumber("old", side === "old" ? row.old : undefined)}{lineNumber("new", side === "new" ? row.new : undefined)}{source(side, row[side])}</tr>] : []);
              }
              return [<tr key={index}>{lineNumber("old", row.old)}{source("old", row.old)}{lineNumber("new", row.new)}{source("new", row.new)}</tr>];
            })();
            if (composer && selection && selected(selection.side, row[selection.side]) && row[selection.side]!.number === Math.max(selection.start, selection.end)) {
              // In Unified, changed old/new rows need the editor after the
              // selected side's row, rather than after both sides.
              const position = unified && !side && rows.length === 2 && selection.side === "old" ? 1 : rows.length;
              rows.splice(position, 0, <tr key="composer"><td colSpan={side ? 2 : unified ? 3 : 4}><InlineComposer node={composer} selection={selection} path={selection.side === "old" ? file.old_path : file.new_path} notice={notice} /></td></tr>);
            }
            return rows;
          })}</tbody></table>
        </div>;
        const label = `${file.new_path || file.old_path} · ${section.new_context || section.old_context || "Changes"}`;
        const content = <>
          {!side && section.fallbacks.map(reason => <p key={reason}>Fallback: {reason}</p>)}
          {side || unified ? section.hunks.map(renderHunk)
            : section.kind === "whole" ? section.hunks.map((hunk, index) => <SplitScrollBlock key={hunk.id} enabled={!wrap} label={`${label} · Hunk ${index + 1}`}>{renderHunk(hunk)}</SplitScrollBlock>)
            : <SplitScrollBlock enabled={!wrap} label={label}>{section.hunks.map(renderHunk)}</SplitScrollBlock>}
        </>;
        return side ? <div key={section.id}>{content}</div> : <details open key={section.id} className="structured-declaration">
          <summary>{section.old_context && section.new_context && section.old_context !== section.new_context
            ? `${section.old_context} → ${section.new_context}`
            : section.new_context || section.old_context || "Changes"}</summary>
          {content}
        </details>;
      })}
    </>}
  </details>;
}

function StructuredDiff({ host, manifest, initial, initialOptions, toolbarMount }: { host: HTMLElement; manifest: Manifest; initial?: FileResult; initialOptions: Options; toolbarMount?: HTMLElement }) {
  const [threads] = useState<Thread[]>(() => [...document.querySelectorAll<HTMLElement>('[data-discussion-anchor]')].flatMap(node => {
    try {
      const anchor = JSON.parse(node.dataset.anchor!);
      if (anchor.base_sha !== manifest.base_sha || anchor.head_sha !== manifest.head_sha) return [];
      return [{ id: node.id, path: anchor.side === "old" ? anchor.old_path : anchor.new_path, side: anchor.side, start: Number(anchor.start_line), end: Number(anchor.end_line), context: anchor.context }];
    } catch { return []; }
  }));
  const [options, setOptions] = useState(initialOptions);
  const [unified, setUnified] = useState(() => matchMedia("(max-width: 800px)").matches);
  const [wrap, setWrap] = useState(true);
  const [notice, setNotice] = useState("");
  const [loader, setLoader] = useState<Loader>();
  const [selection, setSelection] = useState<Selection>();
  const [composerOpen, setComposerOpen] = useState(false);
  const [composer] = useState(() => document.querySelector<HTMLDetailsElement>("#inline-composer") ?? undefined);
  const changeIndex = useRef(-1);
  const viewURL = useRef(host.dataset.viewUrl!);
  const changeOptions = (next: Options) => {
    const url = optionsURL(viewURL.current, next);
    url.hash = location.hash;
    if (host.dispatchEvent(new CustomEvent('moonhub:replace-view-url', {
      bubbles: true, cancelable: true, detail: { url: url.href },
    }))) setOptions(next);
  };
  const pageURL = (page: number) => {
    const url = optionsURL(host.dataset.pageUrl!, options);
    url.searchParams.set('page', String(page));
    return url.href;
  };
  useEffect(() => {
    const next = new Loader(host.dataset.endpoint!, manifest, options); setLoader(next);
    setSelection(undefined); setComposerOpen(false);
    return () => next.dispose();
  }, [host, manifest, options]);
  useEffect(() => {
    const form = document.querySelector<HTMLFormElement>('[data-inline-form]');
    if (!form) return;
    const cancel = form.querySelector<HTMLButtonElement>('[data-inline-cancel]');
    const discard = form.querySelector<HTMLButtonElement>('[data-inline-discard]');
    if (cancel) cancel.hidden = false;
    if (discard) discard.hidden = false;
    const close = () => { const details = form.closest("details"); if (details) details.open = false; setComposerOpen(false); };
    const clear = () => {
      const body = form.elements.namedItem("body") as HTMLTextAreaElement | null;
      if (body?.dataset.imageUploadPending === "true") { body.dispatchEvent(new Event("markdown-upload-blocked")); return; }
      for (const name of ["body", "path", "start_line", "end_line", "document_id", "file_id", "hunk_id", "diff_page", "mode", "ignore_comments", "ignore_tests"]) {
        const input = form.elements.namedItem(name) as HTMLInputElement | HTMLTextAreaElement | null;
        if (input) input.value = "";
      }
      (body ?? form).dispatchEvent(new Event('input', { bubbles: true }));
      setSelection(undefined); setNotice(""); close();
    };
    cancel?.addEventListener('click', close); discard?.addEventListener('click', clear);
    return () => { cancel?.removeEventListener('click', close); discard?.removeEventListener('click', clear); };
  }, [host]);
  const select = (result: FileResult, hunk: Hunk, side: "old" | "new", number: number, extend: boolean) => {
    const form = document.querySelector<HTMLFormElement>('[data-inline-form]');
    if (!form) return;
    const previous = selection;
    const start = extend && previous?.file === result.file.id && previous.hunk === hunk.id && previous.side === side ? previous.start : number;
    const from = Math.min(start, number), end = Math.max(start, number);
    const displayed = new Set(hunk.rows.flatMap(row => row[side] ? [row[side]!.number] : []));
    if (end - from >= 100 || Array.from({ length: end - from + 1 }, (_, i) => from + i).some(n => !displayed.has(n))) { setNotice("Select 1–100 consecutive lines on one side and in one hunk."); return; }
    const field = (name: string) => form.elements.namedItem(name) as HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement | null;
    const body = field("body") as HTMLTextAreaElement | null;
    if (body?.value.trim() || body?.dataset.imageUploadPending === "true") {
      // A click inside the existing range reopens a cancelled draft without
      // shortening its anchor. Other locations must not retarget unsent text.
      const sameRange = previous?.document === result.document_id && previous.file === result.file.id && previous.hunk === hunk.id && previous.side === side && number >= Math.min(previous.start, previous.end) && number <= Math.max(previous.start, previous.end);
      if (sameRange && !extend) {
        setSelection({ ...previous }); setComposerOpen(true);
        setNotice(`${side} lines ${Math.min(previous.start, previous.end)}–${Math.max(previous.start, previous.end)}.`);
      } else setNotice("Your draft keeps its original comparison and lines. Send or discard it before choosing another location.");
      return;
    }
    const values = { document_id: result.document_id, file_id: result.file.id, hunk_id: hunk.id, diff_page: String(manifest.page), mode: result.options.mode, ignore_comments: String(result.options.ignore_comments), ignore_tests: String(result.options.ignore_tests), path: side === "old" ? result.file.old_path : result.file.new_path, side, start_line: String(from), end_line: String(end) };
    for (const [name, value] of Object.entries(values)) { const input = field(name); if (input) input.value = value; }
    setSelection({ document: result.document_id, file: result.file.id, hunk: hunk.id, side, start, end: number });
    setComposerOpen(true);
    setNotice(`${side} lines ${from}–${end}. Shift-click another line to extend the range.`);
    const details = form.closest("details"); if (details) details.open = true;
    form.dispatchEvent(new Event("input", { bubbles: true }));
  };
  const jump = (direction: number) => {
    const changes = [...host.querySelectorAll<HTMLElement>("[data-change]")];
    if (!changes.length) return;
    changeIndex.current = changeIndex.current < 0 ? (direction > 0 ? 0 : changes.length - 1) : (changeIndex.current + direction + changes.length) % changes.length;
    const target = changes[changeIndex.current];
    for (let parent = target.parentElement; parent && parent !== host; parent = parent.parentElement) if (parent instanceof HTMLDetailsElement) parent.open = true;
    target.scrollIntoView({ block: "center" }); target.focus({ preventScroll: true });
  };
  const toolbar = <div className="structured-toolbar">
      <div className="structured-toolbar-group" role="group" aria-label="Comparison options">
        <div className="structured-segmented" role="group" aria-label="Diff algorithm">
          {([["line", "Line"], ["lexical", "Token"], ["ast", "AST"]] as const).map(([mode, label]) => <button type="button" key={mode} aria-pressed={options.mode === mode} onClick={() => { if (options.mode !== mode) changeOptions({ ...options, mode }); }}>{label}</button>)}
        </div>
        <div className="structured-segmented" role="group" aria-label="Diff layout">
          {([true, false] as const).map(value => <button type="button" key={String(value)} aria-pressed={unified === value} onClick={() => setUnified(value)}>{value ? "Unified" : "Split"}</button>)}
        </div>
      </div>
      <div className="structured-toolbar-group" role="group" aria-label="Diff display">
        <label><input type="checkbox" checked={options.ignore_comments} disabled={options.mode === "line"} onChange={e => changeOptions({ ...options, ignore_comments: e.target.checked })} />Ignore comments</label>
        <label><input type="checkbox" checked={options.ignore_tests} disabled={options.mode === "line"} onChange={e => changeOptions({ ...options, ignore_tests: e.target.checked })} />Ignore tests</label>
        <label><input type="checkbox" checked={wrap} onChange={e => setWrap(e.target.checked)} />Wrap lines</label>
      </div>
      <div className="structured-toolbar-group structured-change-navigation" role="group" aria-label="Change navigation">
        <button className="secondary-button" onClick={() => jump(-1)}>Previous change</button><button className="secondary-button" onClick={() => jump(1)}>Next change</button>
      </div>
    </div>;
  return <section className={`structured-diff ${wrap ? "wrap" : "nowrap"}`}>
    {toolbarMount ? createPortal(toolbar, toolbarMount) : toolbar}
    <p role="status">{notice}</p>
    <nav aria-label="Files">{manifest.files.map(file => {
      const url = new URL(pageURL(manifest.page));
      url.searchParams.set('file_id', file.id); url.hash = `diff-file-${file.id}`;
      return <a key={file.id} href={url.href} onClick={event => {
        if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
        event.preventDefault();
        if (!host.dispatchEvent(new CustomEvent('moonhub:replace-view-url', {
          bubbles: true, cancelable: true, detail: { url: url.href },
        }))) return;
        viewURL.current = url.href;
        const node = document.getElementById(`diff-file-${file.id}`);
        if (node instanceof HTMLDetailsElement) { node.open = true; node.scrollIntoView(); }
      }}>{file.new_path || file.old_path}</a>;
    })}</nav>
    {loader && loader.options === options && manifest.files.map(file => <FileView key={`${JSON.stringify(options)}:${file.id}`} file={file} loader={loader} initial={JSON.stringify(options) === JSON.stringify(initialOptions) && initial?.file.id === file.id ? initial : undefined} unified={unified} wrap={wrap} select={select} threads={threads} selection={selection} composer={composerOpen ? composer : undefined} notice={notice} />)}
    {(manifest.page > 1 || manifest.has_more) && <nav aria-label="File pages">
      {manifest.page > 1 && <a href={pageURL(manifest.page - 1)}>Previous files</a>}
      {manifest.has_more && <a href={pageURL(manifest.page + 1)}>Next files</a>}
    </nav>}
  </section>;
}

class MoonhubStructuredDiff extends HTMLElement {
  #root?: Root;
  #mount?: HTMLElement;
  #toolbarMount?: HTMLElement;
  #toolbarFallback?: HTMLElement;
  connectedCallback() {
    queueMicrotask(() => {
      if (!this.isConnected || this.#root) return;
      try {
        const manifest: Manifest = JSON.parse(this.dataset.manifest!);
        if (manifest.protocol !== "moonhub-diff/1") return;
        const options: Options = JSON.parse(this.dataset.options!);
        const initial: FileResult | undefined = this.dataset.selected ? JSON.parse(this.dataset.selected) : undefined;
        this.#mount = document.createElement("div"); this.append(this.#mount);
        const toolbar = this.dataset.toolbarTarget ? document.getElementById(this.dataset.toolbarTarget) : null;
        if (toolbar) {
          this.#toolbarMount = document.createElement("div"); toolbar.append(this.#toolbarMount);
          this.#toolbarFallback = toolbar.querySelector<HTMLElement>("[data-toolbar-fallback]") ?? undefined;
        }
        this.#root = createRoot(this.#mount);
        this.#root.render(<StructuredDiff host={this} manifest={manifest} initial={initial} initialOptions={options} toolbarMount={this.#toolbarMount} />);
        if (this.#toolbarFallback) this.#toolbarFallback.hidden = true;
        const fallback = this.querySelector<HTMLElement>("[data-diff-fallback]"); if (fallback) fallback.hidden = true;
      } catch { /* Retain the readable SSR view if initialization fails. */ }
    });
  }
  disconnectedCallback() {
    this.#root?.unmount(); this.#root = undefined; this.#mount?.remove(); this.#mount = undefined;
    this.#toolbarMount?.remove(); this.#toolbarMount = undefined;
    if (this.#toolbarFallback) this.#toolbarFallback.hidden = false;
    this.#toolbarFallback = undefined;
    const fallback = this.querySelector<HTMLElement>("[data-diff-fallback]"); if (fallback) fallback.hidden = false;
  }
}
if (!customElements.get("moonhub-structured-diff")) customElements.define("moonhub-structured-diff", MoonhubStructuredDiff);
