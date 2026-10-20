import type { ImageInsertion, MarkdownCommand, MarkdownSource } from './markdown-source';

const imageTypes = new Set(['image/png', 'image/jpeg', 'image/gif', 'image/webp']);
const maximumImageBytes = 5 * 1024 * 1024;
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
  addImage.type = 'button'; addImage.textContent = 'Add image'; addImage.className = 'markdown-add-image';
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
    button.addEventListener('mousedown', event => event.preventDefault());
    button.addEventListener('click', () => { source?.command(command); });
  }
  const preview = document.createElement('div');
  preview.className = 'markdown-body markdown-editor-preview'; preview.hidden = true; preview.tabIndex = 0;
  preview.setAttribute('aria-label', 'Markdown preview');
  const help = document.createElement('p');
  help.className = 'markdown-editor-help muted';
  help.textContent = 'Markdown supported. Paste or drop images. PNG, JPEG, GIF, WebP · 5 MiB each.';
  const status = document.createElement('p');
  status.className = 'markdown-editor-status'; status.setAttribute('role', 'status'); status.setAttribute('aria-live', 'polite'); status.hidden = true;
  const retry = document.createElement('button');
  retry.type = 'button'; retry.textContent = 'Retry upload'; retry.hidden = true;
  const picker = document.createElement('input');
  picker.type = 'file'; picker.accept = [...imageTypes].join(','); picker.multiple = true; picker.hidden = true;
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
          if (!editor.isConnected) return;
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
          source.container.addEventListener('dragleave', () => editor.classList.remove('markdown-editor-dragging'));
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
    return 'Upload failed (' + response.status + '). Retry or choose another image.';
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
        showStatus('Uploading ' + (file.name || 'image') + '…');
        let retryable = true;
        try {
          if (!imageTypes.has(file.type)) { retryable = false; throw new Error('Choose a PNG, JPEG, GIF or WebP image.'); }
          if (file.size === 0 || file.size > maximumImageBytes) { retryable = false; throw new Error('Each image must be between 1 byte and 5 MiB.'); }
          const response = await fetch(base + '/attachments?filename=' + encodeURIComponent(file.name || 'image'), { method: 'POST', headers, body: file, credentials: 'same-origin' });
          if (!response.ok) { retryable = response.status >= 500 || response.status === 429; throw new Error(await responseError(response)); }
          const result = await response.json() as { url: string };
          if (!result.url.startsWith(base + '/attachments/') || !/\/[a-f0-9]{64}$/.test(result.url)) throw new Error('The upload returned an invalid image URL. Retry.');
          const alt = (file.name || 'image').replace(/[\[\]\\\r\n]/g, ' ');
          const markdown = '![' + alt + '](' + result.url + ')';
          const position = Math.min(selection, textarea.value.length);
          if (textarea.maxLength > 0 && textarea.value.length + markdown.length > textarea.maxLength) { retryable = false; throw new Error('The image uploaded, but this text is too long. Shorten it and add the image again.'); }
          if (insertion) {
            if (!insertion.insert(markdown)) { retryable = false; throw new Error('Shorten this text, then add the image again.'); }
          } else {
            textarea.setRangeText(markdown, position, position, 'end');
            selection = textarea.selectionStart;
            textarea.dispatchEvent(new Event('input', { bubbles: true }));
          }
          showStatus('Image added.');
        } catch (error) {
          if (retryable) failed.push(file);
          failures.push(error instanceof Error ? error.message : 'Upload failed. Retry or choose another image.');
        } finally {
          pending--; retry.hidden = failed.length === 0;
          if (pending === 0) delete textarea.dataset.imageUploadPending;
          if (pending === 0 && failures.length) showStatus([...new Set(failures)].join(' ') + ' Your text is preserved.', true);
        }
      });
    }
    queue = queue.then(() => insertion?.clear());
  }

  textarea.addEventListener('select', () => { selection = textarea.selectionStart; });
  textarea.addEventListener('focus', () => { void ensureSource(true); });
  textarea.addEventListener('markdown-focus', event => { event.preventDefault(); writeMode(true); });
  textarea.addEventListener('markdown-upload-blocked', () => showStatus('Wait for image uploads to finish before discarding this draft.'));
  textarea.addEventListener('input', () => { selection = textarea.selectionStart; });
  addImage.addEventListener('click', () => picker.click());
  picker.addEventListener('change', () => { upload([...picker.files ?? []]); picker.value = ''; });
  retry.addEventListener('click', () => { const files = failed; failed = []; failures = []; retry.hidden = true; upload(files); });
  edit.addEventListener('click', () => writeMode());
  previewButton.addEventListener('click', async () => {
    if (pending > 0) { showStatus('Wait for image uploads to finish, then preview.'); return; }
    const request = ++previewRequest;
    previewing = true; formats.hidden = true; source?.show(false);
    preview.textContent = 'Loading preview…'; preview.hidden = false; textarea.hidden = true;
    edit.setAttribute('aria-pressed', 'false'); previewButton.setAttribute('aria-pressed', 'true'); addImage.disabled = true;
    if (!textarea.value.trim()) { preview.textContent = 'Nothing to preview yet.'; return; }
    try {
      const response = await fetch(base + '/markdown-preview', { method: 'POST', headers: { ...headers, 'Content-Type': 'text/plain; charset=utf-8' }, body: textarea.value, credentials: 'same-origin' });
      if (!response.ok) throw new Error('Preview failed. Switch to Write and try again.');
      const html = await response.text();
      if (request === previewRequest) preview.innerHTML = html;
    } catch (error) { if (request === previewRequest) preview.textContent = error instanceof Error ? error.message : 'Preview failed. Try again.'; }
  });
  function handlePaste(event: ClipboardEvent) {
    const files = [...event.clipboardData?.items ?? []].filter(item => item.kind === 'file' && item.type.startsWith('image/')).map(item => item.getAsFile()).filter((file): file is File => file !== null);
    if (files.length) { event.preventDefault(); (event as Event & { codemirrorIgnore?: boolean }).codemirrorIgnore = true; upload(files); }
  }
  textarea.addEventListener('paste', handlePaste);
  textarea.addEventListener('dragover', event => {
    if (event.dataTransfer?.types.includes('Files')) { event.preventDefault(); editor.classList.add('markdown-editor-dragging'); }
  });
  textarea.addEventListener('dragleave', () => editor.classList.remove('markdown-editor-dragging'));
  textarea.addEventListener('drop', event => {
    editor.classList.remove('markdown-editor-dragging');
    const files = [...event.dataTransfer?.files ?? []];
    if (files.length) { event.preventDefault(); upload(files); }
  });
  form.addEventListener('submit', event => {
    if (pending > 0) { event.preventDefault(); event.stopImmediatePropagation(); showStatus('Wait for image uploads to finish before submitting.'); }
    else if (required && !textarea.value.trim()) { event.preventDefault(); event.stopImmediatePropagation(); writeMode(); showStatus('Write a comment before submitting.', true); }
  }, { capture: true });
  const visibility = new ResizeObserver(() => {
    if (editor.getBoundingClientRect().width > 0 && !previewing) void ensureSource();
  });
  visibility.observe(editor);
}
