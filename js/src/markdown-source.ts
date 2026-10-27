import EasyMDE from 'easymde';
import type { TextMarker } from 'codemirror';
import 'easymde/dist/easymde.min.css';

export type MarkdownCommand = 'bold' | 'heading' | 'quote' | 'code' | 'link' | 'unordered-list' | 'ordered-list' | 'undo' | 'redo';

export interface ImageInsertion {
  insert(text: string): boolean;
  clear(): void;
}

// The original textarea owns submission and drafts; EasyMDE owns editing/history.
export function createMarkdownSource(textarea: HTMLTextAreaElement, onLimit: () => void) {
  const height = Math.max(110, Math.min(320, textarea.rows * 22));
  const instance = new EasyMDE({
    element: textarea, forceSync: true, toolbar: false, status: false,
    autoDownloadFontAwesome: false, spellChecker: false, nativeSpellcheck: true,
    autofocus: false, autoRefresh: false, minHeight: height + 'px',
    previewImagesInEditor: false, uploadImage: false, lineWrapping: true,
    blockStyles: { bold: '**', code: String.fromCharCode(96).repeat(3) }, unorderedListStyle: '-',
    shortcuts: {
      toggleItalic: null, toggleCheckList: null, drawImage: null,
      togglePreview: null, toggleSideBySide: null, toggleFullScreen: null,
      toggleHeadingSmaller: null, toggleHeadingBigger: null, cleanBlock: null,
    },
  });
  const cm = instance.codemirror;
  const wrapper = cm.getWrapperElement();
  const container = wrapper.parentElement!;
  container.removeAttribute('role');
  cm.getInputField().setAttribute('aria-label', textarea.getAttribute('aria-label') || textarea.name || 'Markdown source');
  const extraKeys = cm.getOption('extraKeys');
  cm.setOption('extraKeys', { ...(typeof extraKeys === 'object' ? extraKeys : {}), Tab: false, 'Shift-Tab': false, Esc: false });
  cm.on('beforeChange', (editor, change) => {
    if (textarea.maxLength < 0) return;
    const length = editor.getValue().length - (editor.indexFromPos(change.to) - editor.indexFromPos(change.from)) + change.text.join('\n').length;
    if (length > textarea.maxLength) { change.cancel(); onLimit(); }
  });
  cm.on('change', () => {
    textarea.value = cm.getValue();
    textarea.dispatchEvent(new Event('input', { bubbles: true }));
  });
  const sync = () => { if (cm.getValue() !== textarea.value) cm.setValue(textarea.value); };
  textarea.addEventListener('input', sync);
  textarea.dataset.markdownSource = 'easymde';

  return {
    cm, container,
    destroy() { textarea.removeEventListener("input", sync); instance.toTextArea(); delete textarea.dataset.markdownSource; },
    focus() { sync(); cm.refresh(); cm.focus(); },
    refresh() { sync(); cm.refresh(); },
    show(visible: boolean) { container.hidden = !visible; if (visible) cm.refresh(); },
    command(command: MarkdownCommand) {
      const actions = {
        bold: EasyMDE.toggleBold, heading: EasyMDE.toggleHeading1,
        quote: EasyMDE.toggleBlockquote, code: EasyMDE.toggleCodeBlock,
        link: EasyMDE.drawLink, 'unordered-list': EasyMDE.toggleUnorderedList,
        'ordered-list': EasyMDE.toggleOrderedList, undo: EasyMDE.undo, redo: EasyMDE.redo,
      };
      actions[command](instance);
    },
    bookmark(position?: number): ImageInsertion {
      let marker: TextMarker | null = cm.setBookmark(position === undefined ? cm.getCursor() : cm.posFromIndex(position), { insertLeft: false });
      return {
        insert(text) {
          const at = marker?.find();
          if (!at || 'from' in at) return false;
          if (textarea.maxLength >= 0 && cm.getValue().length + text.length > textarea.maxLength) { onLimit(); return false; }
          const index = cm.indexFromPos(at);
          cm.replaceRange(text, at, at, '+image');
          marker?.clear();
          marker = cm.setBookmark(cm.posFromIndex(index + text.length), { insertLeft: false });
          return true;
        },
        clear() { marker?.clear(); marker = null; },
      };
    },
  };
}

export type MarkdownSource = ReturnType<typeof createMarkdownSource>;
