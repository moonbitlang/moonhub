// Each navigation supplies a fresh AbortSignal through the existing page lifetime.
export function mountRepositoryBrowser(signal: AbortSignal) {
  const finder = document.querySelector<HTMLDetailsElement>('[data-file-finder]');
  const query = finder?.querySelector<HTMLInputElement>('[data-file-query]');
  const results = [...(finder?.querySelectorAll<HTMLElement>('[data-file-result]') ?? [])];
  query?.addEventListener('input', () => {
    const value = query.value.trim().toLocaleLowerCase();
    let count = 0;
    for (const result of results) {
      result.hidden = !result.textContent?.toLocaleLowerCase().includes(value);
      if (!result.hidden) count++;
    }
    const status = finder?.querySelector<HTMLElement>('[data-file-count]');
    if (status) status.textContent = `${count} matching files`;
  }, { signal });
  finder?.addEventListener('toggle', () => { if (finder.open) query?.focus(); }, { signal });

  document.addEventListener('keydown', event => {
    const target = event.composedPath()[0];
    if (event.defaultPrevented || event.ctrlKey || event.metaKey || event.altKey ||
      target instanceof HTMLElement && (target.isContentEditable || target.closest('input, textarea, select, [contenteditable], .CodeMirror, .EasyMDEContainer, [role=textbox]'))) return;
    if (event.key === '/' && !event.shiftKey) {
      const search = [...document.querySelectorAll<HTMLInputElement>('main input[type=search], main [data-list-filter], main input[name=branch]')]
        .find(input => input.checkVisibility());
      if (search) { event.preventDefault(); search.focus(); search.select(); }
    }
    if (event.key === 't' && finder) { event.preventDefault(); finder.open = true; query?.focus(); }
  }, { signal });

  const source = document.querySelector<HTMLElement>('[data-file-source]')?.textContent ?? '';
  const path = document.querySelector<HTMLElement>('[data-file-name]')?.textContent ?? '';
  for (const button of document.querySelectorAll<HTMLButtonElement>('[data-copy-file], [data-copy-path], [data-copy-reference]')) {
    button.hidden = false;
    button.addEventListener('click', async () => {
      const status = document.querySelector<HTMLElement>('[data-copy-status]');
      try {
        await navigator.clipboard.writeText(button.dataset.copyReference ?? (button.hasAttribute('data-copy-file') ? source : path));
        if (!signal.aborted && status) status.textContent = 'Copied.';
      } catch {
        if (!signal.aborted && status) status.textContent = 'Clipboard unavailable. Select the text and copy it manually.';
      }
    }, { signal });
  }
  const preview = document.querySelector<HTMLElement>('[data-file-preview]');
  const code = document.querySelector<HTMLElement>('[data-file-code]');
  const tabs = [...document.querySelectorAll<HTMLButtonElement>('[data-file-tab]')];
  if (preview && code) {
    const container = document.querySelector<HTMLElement>('.file-preview-tabs');
    if (container) container.hidden = false;
    const show = (view: string) => {
      preview.hidden = view !== 'preview'; code.hidden = view !== 'code';
      for (const tab of tabs) tab.setAttribute('aria-pressed', String(tab.dataset.fileTab === view));
      if (view === 'code') window.dispatchEvent(new Event('resize'));
    };
    show(/^#L\d+/.test(location.hash) ? 'code' : 'preview');
    tabs.forEach(tab => tab.addEventListener('click', () => show(tab.dataset.fileTab!), { signal }));
    window.addEventListener('hashchange', () => { if (/^#L\d+/.test(location.hash)) show('code'); }, { signal });
  }
}
