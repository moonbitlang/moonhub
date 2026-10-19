const imageTypes = new Set(['image/png', 'image/jpeg', 'image/gif', 'image/webp']);
const maximumImageBytes = 5 * 1024 * 1024;

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
  editor.append(toolbar, textarea, preview, help, status, retry, picker);
  let pending = 0;
  let failed: File[] = [];
  let failures: string[] = [];
  let queue = Promise.resolve();
  let previewRequest = 0;
  let selection = textarea.selectionStart;

  function showStatus(message: string, error = false) {
    status.textContent = message; status.hidden = false;
    status.classList.toggle('error', error);
  }

  function writeMode(focus = true) {
    previewRequest++;
    textarea.hidden = false; preview.hidden = true;
    edit.setAttribute('aria-pressed', 'true'); previewButton.setAttribute('aria-pressed', 'false');
    addImage.disabled = false;
    if (focus) textarea.focus();
  }

  async function responseError(response: Response) {
    if ((response.headers.get('content-type') ?? '').includes('application/json')) {
      const body = await response.json().catch(() => null) as { error?: { message?: string } } | null;
      if (body?.error?.message) return body.error.message;
    }
    if (response.status === 401 || response.status === 403) return 'Your session or access changed. Reload this page, then retry.';
    return 'Upload failed (' + response.status + '). Retry or choose another image.';
  }

  function upload(files: File[]) {
    if (!files.length) return;
    if (pending === 0) { failed = []; failures = []; retry.hidden = true; }
    writeMode(false);
    selection = textarea.selectionStart;
    for (const file of files) {
      pending++;
      textarea.dataset.imageUploadPending = 'true';
      queue = queue.then(async () => {
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
          textarea.setRangeText(markdown, position, position, 'end');
          selection = textarea.selectionStart;
          textarea.dispatchEvent(new Event('input', { bubbles: true }));
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
  }

  textarea.addEventListener('select', () => { selection = textarea.selectionStart; });
  textarea.addEventListener('markdown-upload-blocked', () => showStatus('Wait for image uploads to finish before discarding this draft.'));
  textarea.addEventListener('input', () => { selection = textarea.selectionStart; });
  addImage.addEventListener('click', () => picker.click());
  picker.addEventListener('change', () => { upload([...picker.files ?? []]); picker.value = ''; });
  retry.addEventListener('click', () => { const files = failed; failed = []; failures = []; retry.hidden = true; upload(files); });
  edit.addEventListener('click', () => writeMode());
  previewButton.addEventListener('click', async () => {
    if (pending > 0) { showStatus('Wait for image uploads to finish, then preview.'); return; }
    const request = ++previewRequest;
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
  textarea.addEventListener('paste', event => {
    const files = [...event.clipboardData?.items ?? []].filter(item => item.kind === 'file' && item.type.startsWith('image/')).map(item => item.getAsFile()).filter((file): file is File => file !== null);
    if (files.length) { event.preventDefault(); upload(files); }
  });
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
  }, { capture: true });
}
