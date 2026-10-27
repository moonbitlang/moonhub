import type { ImageInsertion, MarkdownCommand, MarkdownSource } from './markdown-source';

export function mountMarkdownEditors(signal: AbortSignal) {

  const imageTypes = new Set(['image/png', 'image/jpeg', 'image/gif', 'image/webp']);
  const maximumImageBytes = 5 * 1024 * 1024;
  const maximumAttachmentBytes = 25 * 1024 * 1024;
  let sourceModule: Promise<typeof import('./markdown-source')> | undefined;

  for (const textarea of document.querySelectorAll<HTMLTextAreaElement>('textarea[name=body], textarea[name=description]')) {
    const form = textarea.form;
    if (!form) continue;
    const action = new URL(form.action, location.href);
    const match = action.pathname.match(/^\/([^/]+)\/([^/]+)\/(issues|merge-requests)(?:\/|$)/);
    const token = form.querySelector<HTMLInputElement>('input[name=csrf_token]')?.value;
    if (!match || !token || action.origin !== location.origin) continue;
    const base = '/' + match[1] + '/' + match[2];
    const headers = { 'X-CSRF-Token': token, 'X-CSRF-Scope': match[3] };
    const editor = document.createElement('div');
    editor.className = 'markdown-editor';
    const label = textarea.parentElement;
    if (label instanceof HTMLLabelElement && label.classList.contains('field')) {
      const field = document.createElement('div'); field.className = label.className;
      const text = label.querySelector('span')?.textContent;
      if (text && !textarea.hasAttribute('aria-label')) textarea.setAttribute('aria-label', text);
      field.append(...label.childNodes); label.replaceWith(field);
    }
    textarea.before(editor);
    const toolbar = document.createElement('div');
    toolbar.className = 'markdown-editor-toolbar';
    toolbar.setAttribute('role', 'group');
    toolbar.setAttribute('aria-label', 'Markdown editor');
    const edit = document.createElement('button');
    edit.type = 'button'; edit.textContent = 'Write'; edit.setAttribute('aria-pressed', 'true');
    const previewButton = document.createElement('button');
    previewButton.type = 'button'; previewButton.textContent = 'Preview'; previewButton.setAttribute('aria-pressed', 'false');
    const addImage = document.createElement('button');
    addImage.type = 'button'; addImage.textContent = 'Attach files'; addImage.className = 'markdown-add-image';
    toolbar.append(edit, previewButton, addImage);
    const formats = document.createElement('div');
    formats.className = 'markdown-editor-formats'; formats.hidden = true;
    formats.setAttribute('role', 'group'); formats.setAttribute('aria-label', 'Markdown formatting');
    const commands: [MarkdownCommand, string, string][] = [
      ['bold', 'Bold', 'bold'], ['heading', 'Heading', 'heading'], ['quote', 'Quote', 'quote'],
      ['code', 'Code', 'code'], ['link', 'Insert link', 'link'],
      ['unordered-list', 'Bulleted list', 'list'], ['ordered-list', 'Numbered list', 'list-ordered'],
      ['undo', 'Undo', 'undo'], ['redo', 'Redo', 'redo'],
    ];
    for (const [command, label, icon] of commands) {
      const button = document.createElement('button'); button.type = 'button';
      button.title = label; button.setAttribute('aria-label', label);
      const glyph = document.createElement('span'); glyph.className = 'ui-icon'; glyph.dataset.icon = icon; glyph.setAttribute('aria-hidden', 'true');
      button.append(glyph); formats.append(button);
      button.addEventListener('mousedown', event => event.preventDefault(), { signal });
      button.addEventListener('click', () => { source?.command(command); }, { signal });
    }
    const preview = document.createElement('div');
    preview.className = 'markdown-body markdown-editor-preview'; preview.hidden = true; preview.tabIndex = 0;
    preview.setAttribute('aria-label', 'Markdown preview');
    const help = document.createElement('p');
    help.className = 'markdown-editor-help muted';
    help.textContent = 'Paste or drop files. Images up to 5 MiB; other files up to 25 MiB. Up to 8 attachments per body.';
    const status = document.createElement('p');
    status.className = 'markdown-editor-status'; status.setAttribute('role', 'status'); status.setAttribute('aria-live', 'polite'); status.hidden = true;
    const retry = document.createElement('button');
    retry.type = 'button'; retry.textContent = 'Retry upload'; retry.hidden = true;
    const picker = document.createElement('input');
    picker.type = 'file'; picker.multiple = true; picker.hidden = true;
    editor.append(toolbar, formats, textarea, preview, help, status, retry, picker);
    let pending = 0;
    let failed: File[] = [];
    let failures: string[] = [];
    let queue = Promise.resolve();
    let previewRequest = 0;
    let selection = textarea.selectionStart;
    let source: MarkdownSource | undefined;
    let loading: Promise<MarkdownSource | undefined> | undefined;
    const required = textarea.required;
    let previewing = false;

    async function ensureSource(focus = false) {
      if (source) { if (focus) source.focus(); else source.refresh(); return source; }
      if (!loading) {
        loading = (async () => {
          try {
            sourceModule ??= import('./markdown-source').catch(error => { sourceModule = undefined; throw error; });
            const { createMarkdownSource } = await sourceModule;
            if (signal.aborted || !editor.isConnected) return;
            source = createMarkdownSource(textarea, () => showStatus('Markdown must contain at most ' + textarea.maxLength + ' characters.', true));
            textarea.required = false;
            formats.hidden = previewing;
            source.show(!previewing);
            source.cm.on('paste', (_cm, event) => handlePaste(event));
            source.cm.on('drop', (cm, event) => {
              editor.classList.remove('markdown-editor-dragging');
              const files = [...event.dataTransfer?.files ?? []];
              if (!files.length) return;
              event.preventDefault(); (event as Event & { codemirrorIgnore?: boolean }).codemirrorIgnore = true;
              const position = cm.coordsChar({ left: event.clientX, top: event.clientY }, 'window');
              upload(files, cm.indexFromPos(position));
            });
            source.cm.on('dragover', (_cm, event) => {
              if (event.dataTransfer?.types.includes('Files')) { event.preventDefault(); editor.classList.add('markdown-editor-dragging'); }
            });
            source.container.addEventListener('dragleave', () => editor.classList.remove('markdown-editor-dragging'), { signal });
            return source;
          } catch {
            showStatus('The enhanced editor could not load. You can keep writing here, or select Write to retry.', true);
          } finally { loading = undefined; }
        })();
      }
      const result = await loading;
      if (focus && !previewing) result?.focus();
      return result;
    }

    function showStatus(message: string, error = false) {
      status.textContent = message; status.hidden = false;
      status.classList.toggle('error', error);
    }

    function writeMode(focus = true) {
      previewRequest++;
      previewing = false;
      textarea.hidden = !!source; preview.hidden = true;
      source?.show(true); formats.hidden = !source;
      edit.setAttribute('aria-pressed', 'true'); previewButton.setAttribute('aria-pressed', 'false');
      addImage.disabled = false;
      if (focus) { if (source) source.focus(); else textarea.focus(); }
      void ensureSource(focus);
    }

    async function responseError(response: Response) {
      if ((response.headers.get('content-type') ?? '').includes('application/json')) {
        const body = await response.json().catch(() => null) as { error?: { message?: string } } | null;
        if (body?.error?.message) return body.error.message;
      }
      if (response.status === 401 || response.status === 403) return 'Your session or access changed. Reload this page, then retry.';
      return 'Upload failed (' + response.status + '). Retry or choose another file.';
    }

    function upload(files: File[], position?: number) {
      if (!files.length) return;
      if (pending === 0) { failed = []; failures = []; retry.hidden = true; }
      writeMode(false);
      selection = position ?? textarea.selectionStart;
      let insertion: ImageInsertion | undefined;
      const ready = ensureSource().then(active => { insertion = active?.bookmark(position); });
      for (const file of files) {
        pending++;
        textarea.dataset.imageUploadPending = 'true';
        queue = queue.then(async () => {
          await ready;
          if (signal.aborted) { pending--; return; }
          showStatus('Uploading ' + (file.name || 'attachment') + '…');
          let retryable = true;
          try {
            const limit = imageTypes.has(file.type) ? maximumImageBytes : maximumAttachmentBytes;
            if (file.size === 0 || file.size > limit) { retryable = false; throw new Error('Each file must be between 1 byte and ' + (limit / 1024 / 1024) + ' MiB.'); }
            const response = await fetch(base + '/attachments?filename=' + encodeURIComponent(file.name || 'attachment'), { method: 'POST', headers, body: file, credentials: 'same-origin', signal });
            if (!response.ok) { retryable = response.status >= 500 || response.status === 429; throw new Error(await responseError(response)); }
            const result = await response.json() as { url: string; markdown: string; media_type: string };
            if (!result.url.startsWith(base + '/attachments/') || !/\/[a-f0-9]{64}$/.test(result.url) || typeof result.markdown !== 'string') throw new Error('The upload returned an invalid attachment. Retry.');
            const markdown = result.markdown;
            const position = Math.min(selection, textarea.value.length);
            if (textarea.maxLength > 0 && textarea.value.length + markdown.length > textarea.maxLength) { retryable = false; throw new Error('The file uploaded, but this text is too long. Shorten it and attach the file again.'); }
            if (insertion) {
              if (!insertion.insert(markdown)) { retryable = false; throw new Error('Shorten this text, then attach the file again.'); }
            } else {
              textarea.setRangeText(markdown, position, position, 'end');
              selection = textarea.selectionStart;
              textarea.dispatchEvent(new Event('input', { bubbles: true }));
            }
            showStatus(imageTypes.has(result.media_type) ? 'Image added.' : 'File attached.');
          } catch (error) {
            if (retryable) failed.push(file);
            failures.push(error instanceof Error ? error.message : 'Upload failed. Retry or choose another file.');
          } finally {
            pending--; retry.hidden = failed.length === 0;
            if (pending === 0) delete textarea.dataset.imageUploadPending;
            if (pending === 0 && failures.length) showStatus([...new Set(failures)].join(' ') + ' Your text is preserved.', true);
          }
        });
      }
      queue = queue.then(() => insertion?.clear());
    }

    textarea.addEventListener('select', () => { selection = textarea.selectionStart; }, { signal });
    textarea.addEventListener('focus', () => { void ensureSource(true); }, { signal });
    textarea.addEventListener('markdown-focus', event => { event.preventDefault(); writeMode(true); }, { signal });
    textarea.addEventListener('markdown-upload-blocked', () => showStatus('Wait for file uploads to finish before discarding this draft.'), { signal });
    textarea.addEventListener('input', () => { selection = textarea.selectionStart; }, { signal });
    addImage.addEventListener('click', () => picker.click(), { signal });
    picker.addEventListener('change', () => { upload([...picker.files ?? []]); picker.value = ''; }, { signal });
    retry.addEventListener('click', () => { const files = failed; failed = []; failures = []; retry.hidden = true; upload(files); }, { signal });
    edit.addEventListener('click', () => writeMode(), { signal });
    previewButton.addEventListener('click', async () => {
      if (pending > 0) { showStatus('Wait for file uploads to finish, then preview.'); return; }
      const request = ++previewRequest;
      previewing = true; formats.hidden = true; source?.show(false);
      preview.textContent = 'Loading preview…'; preview.hidden = false; textarea.hidden = true;
      edit.setAttribute('aria-pressed', 'false'); previewButton.setAttribute('aria-pressed', 'true'); addImage.disabled = true;
      if (!textarea.value.trim()) { preview.textContent = 'Nothing to preview yet.'; return; }
      try {
        const response = await fetch(base + '/markdown-preview', { method: 'POST', headers: { ...headers, 'Content-Type': 'text/plain; charset=utf-8' }, body: textarea.value, credentials: 'same-origin', signal });
        if (!response.ok) throw new Error('Preview failed. Switch to Write and try again.');
        const html = await response.text();
        if (request === previewRequest) preview.innerHTML = html;
      } catch (error) { if (request === previewRequest) preview.textContent = error instanceof Error ? error.message : 'Preview failed. Try again.'; }
    }, { signal });
    function handlePaste(event: ClipboardEvent) {
      const files = [...event.clipboardData?.items ?? []].filter(item => item.kind === 'file').map(item => item.getAsFile()).filter((file): file is File => file !== null);
      if (files.length) { event.preventDefault(); (event as Event & { codemirrorIgnore?: boolean }).codemirrorIgnore = true; upload(files); }
    }
    textarea.addEventListener('paste', handlePaste, { signal });
    textarea.addEventListener('dragover', event => {
      if (event.dataTransfer?.types.includes('Files')) { event.preventDefault(); editor.classList.add('markdown-editor-dragging'); }
    }, { signal });
    textarea.addEventListener('dragleave', () => editor.classList.remove('markdown-editor-dragging'), { signal });
    textarea.addEventListener('drop', event => {
      editor.classList.remove('markdown-editor-dragging');
      const files = [...event.dataTransfer?.files ?? []];
      if (files.length) { event.preventDefault(); upload(files); }
    }, { signal });
    form.addEventListener('submit', event => {
      if (pending > 0) { event.preventDefault(); event.stopImmediatePropagation(); showStatus('Wait for file uploads to finish before submitting.'); }
      else if (required && !textarea.value.trim()) { event.preventDefault(); event.stopImmediatePropagation(); writeMode(); showStatus('Write a comment before submitting.', true); }
    }, { capture: true , signal });
    const visibility = new ResizeObserver(() => {
      if (editor.getBoundingClientRect().width > 0 && !previewing) void ensureSource();
    });
    signal.addEventListener("abort", () => { visibility.disconnect(); source?.destroy(); previewRequest++; }, { once: true });
    document.addEventListener("moonhub:before-navigate", event => { if (pending > 0) { event.preventDefault(); showStatus("Wait for file uploads to finish before leaving this page."); } }, { signal });
    visibility.observe(editor);
  }

}
