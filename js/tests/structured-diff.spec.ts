import { test, expect, type Page } from '@playwright/test';

async function login(page: Page) {
  await page.goto('/-/login');
  await expect(page.locator('html')).toHaveAttribute('data-hydrated', 'true');
  await page.locator('[name=name_key]').fill('alice');
  await page.locator('[name=password]').fill('browser-test-password');
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  // Password verification can outlast the default five-second assertion on a
  // loaded CI host. Still require the successful redirect before diff checks.
  await expect(page).toHaveURL(/\/$/, { timeout: 15000 });
}

async function commitPage(page: Page) {
  await page.goto('/alice/demo/commits?rev=moondiff-feature');
  await page.getByRole('row').filter({ hasText: 'MoonDiff reordered declarations' }).getByRole('link').click();
  await expect(page.locator('.structured-diff')).toBeVisible();
}

test('commit MoonDiff modes, server pairing, worker highlighting and SPA remount', async ({ page }) => {
  const errors: string[] = [];
  page.on('pageerror', e => errors.push(e.message));
  await login(page);
  await commitPage(page);
  const commit = page.url();
  const header = page.locator('.site-header');
  const algorithm = header.getByRole('group', { name: 'Diff algorithm', exact: true });
  const layout = header.getByRole('group', { name: 'Diff layout', exact: true });
  await expect(algorithm.getByRole('button')).toHaveText(['Line', 'Token', 'AST']);
  await expect(layout.getByRole('button')).toHaveText(['Unified', 'Split']);
  await expect(algorithm.getByRole('button', { name: 'Token', exact: true })).toHaveAttribute('aria-pressed', 'true');
  await expect(layout.getByRole('button', { name: 'Split', exact: true })).toHaveAttribute('aria-pressed', 'true');

  await expect(header.locator('.structured-toolbar')).toHaveCount(1);
  await expect(page.locator('main .structured-toolbar')).toHaveCount(0);
  await expect(header.locator('.brand-area, .breadcrumbs, .header-inbox')).toHaveCount(0);
  await expect(header.getByRole('link', { name: 'moonhub home' })).toHaveAttribute('href', '/');
  await expect(header.locator('.brand [data-icon=moon]')).toBeVisible();
  await expect(header.getByLabel('Account menu', { exact: true })).toBeVisible();
  const source = page.locator('.structured-file').filter({ has: page.locator('summary', { hasText: 'main.mbt' }) }).first();
  await expect(source.getByText(/Declaration order changed:/)).toBeVisible();
  await expect(source.getByRole('button', { name: 'new line 1', exact: true })).toBeVisible();
  await expect(source.locator('.segment-changed').first()).toBeVisible();
  await page.getByRole('button', { name: 'AST', exact: true }).click();
  await expect(page.getByRole('button', { name: 'AST', exact: true })).toHaveAttribute('aria-pressed', 'true');
  await expect(algorithm.locator('[aria-pressed=true]')).toHaveCount(1);
  await expect(algorithm.getByRole('button', { name: 'AST', exact: true })).toHaveCSS('font-weight', '700');
  await expect(algorithm.getByRole('button', { name: 'AST', exact: true })).toHaveCSS('color', 'rgb(23, 105, 210)');
  await expect(algorithm.getByRole('button', { name: 'Token', exact: true })).toHaveCSS('font-weight', '400');
  await expect(source.getByText(/Declaration order changed:/)).toBeVisible();
  await page.getByRole('button', { name: 'Line', exact: true }).click();
  await expect(page.getByLabel('Ignore comments', { exact: true })).toBeDisabled();
  await expect(source.getByText('changed · line', { exact: true })).toBeVisible();
  await page.getByRole('button', { name: 'Unified', exact: true }).click();
  await expect(source.locator('table').first()).toHaveClass('unified');
  await expect(layout.locator('[aria-pressed=true]')).toHaveCount(1);
  await expect(layout.getByRole('button', { name: 'Unified', exact: true })).toHaveAttribute('aria-pressed', 'true');
  await expect(layout.getByRole('button', { name: 'Unified', exact: true })).toHaveCSS('font-weight', '700');
  await expect(layout.getByRole('button', { name: 'Unified', exact: true })).toHaveCSS('color', 'rgb(23, 105, 210)');
  await layout.getByRole('button', { name: 'Split', exact: true }).click();
  await expect(source.locator('table').first()).toHaveClass('split');
  await expect(layout.getByRole('button', { name: 'Split', exact: true })).toHaveAttribute('aria-pressed', 'true');
  await page.getByLabel('Wrap lines', { exact: true }).uncheck();
  await expect(page.locator('.structured-diff')).toHaveClass(/nowrap/);
  await page.getByRole('button', { name: 'Next change', exact: true }).click();
  await page.getByRole('link', { name: 'Files', exact: true }).first().click();
  await expect(header.locator('.structured-toolbar')).toHaveCount(0);
  await expect(header.locator('.brand-area, .breadcrumbs, .header-inbox')).toHaveCount(3);
  await page.goBack();
  await expect(header.locator('.structured-toolbar')).toHaveCount(1);
  await expect(header.getByRole('button', { name: 'Line', exact: true })).toHaveAttribute('aria-pressed', 'true');
  await page.goto(commit);
  await expect(page.locator('.structured-toolbar')).toHaveCount(1);
  await expect(source.getByText(/Declaration order changed:/)).toBeVisible();
  expect(errors).toEqual([]);
});

test('selected file remains readable without JavaScript', async ({ page, browser }) => {
  await login(page);
  await commitPage(page);
  const state = await page.context().storageState();
  const manifest = await page.locator('moonhub-structured-diff').getAttribute('data-manifest');
  const file = JSON.parse(manifest!).files.find((f: { new_path: string }) => f.new_path === 'main.mbt');
  const url = new URL(page.url()); url.searchParams.set('file_id', file.id);
  const context = await browser.newContext({ javaScriptEnabled: false, storageState: state });
  const native = await context.newPage();
  await native.goto(url.href);
  await expect(native.locator('[data-diff-fallback]')).toContainText('new 1: fn b() { 3 }');
  await expect(native.locator('.site-header').getByRole('link', { name: 'line', exact: true })).toBeVisible();
  await expect(native.locator('.site-header .brand-area, .site-header .breadcrumbs, .site-header .header-inbox')).toHaveCount(0);
  await expect(native.locator('.site-header .brand [data-icon=moon]')).toBeVisible();
  await expect(native.locator('[data-diff-fallback] nav[aria-label="Diff options"]')).toHaveCount(0);
  await context.close();
});

test('obsolete file loads are cancelled on mode change and cannot overwrite current mode', async ({ page }) => {
  await login(page);
  let pending = 0, peak = 0;
  await page.route('**/commit/*/diff?*', async route => {
    pending++; peak = Math.max(peak, pending);
    const mode = new URL(route.request().url()).searchParams.get('mode');
    if (mode === 'lexical') await new Promise(resolve => setTimeout(resolve, 250));
    try { await route.continue(); } catch { /* Aborted generation. */ }
    pending--;
  });
  await commitPage(page);
  await page.getByRole('button', { name: 'Line', exact: true }).click();
  await expect(page.locator('.structured-file').first().getByText('changed · line', { exact: true })).toBeVisible();
  await page.waitForTimeout(300);
  await expect(page.getByRole('button', { name: 'Line', exact: true })).toHaveAttribute('aria-pressed', 'true');
  // New generations cancel old requests; each generation admits at most two.
  expect(peak).toBeLessThanOrEqual(4);
});

test('MR inline drafts keep their document and source coordinates across mode changes and navigation', async ({ page, browser }) => {
  await login(page);
  await page.goto('/alice/demo/merge-requests/new');
  await page.getByLabel('Source branch', { exact: true }).selectOption('moondiff-feature');
  await page.getByLabel('Target branch', { exact: true }).selectOption('moondiff-base');
  await page.getByLabel('Title', { exact: true }).fill('MoonDiff browser review');
  await page.getByRole('button', { name: 'Create merge request', exact: true }).click();
  await expect(page).toHaveURL(/\/merge-requests\/\d+$/);
  await page.getByRole('link', { name: 'Changes', exact: true }).click();
  const header = page.locator('.site-header');
  await expect(header.locator('.structured-toolbar')).toHaveCount(1);
  await expect(page.locator('main .structured-toolbar')).toHaveCount(0);
  await expect(header.locator('.brand-area, .breadcrumbs, .header-inbox')).toHaveCount(0);
  await expect(header.getByLabel('Account menu', { exact: true })).toBeVisible();
  const native = await browser.newContext({ javaScriptEnabled: false, storageState: await page.context().storageState() });
  const nativePage = await native.newPage();
  await nativePage.goto(page.url());
  await expect(nativePage.locator('.site-header').getByRole('navigation', { name: 'Diff options', exact: true })).toBeVisible();
  await expect(nativePage.locator('.site-header .breadcrumbs, main nav[aria-label="Diff options"]')).toHaveCount(0);
  await native.close();
  await page.getByRole('button', { name: 'new line 1', exact: true }).click();
  const form = page.locator('[data-inline-form]');
  const document = await form.locator('[name=document_id]').inputValue();
  expect(document).toHaveLength(64);
  await expect(form.locator('.CodeMirror')).toBeVisible();
  await form.locator('.CodeMirror').click();
  await page.keyboard.insertText('Keep this original location');
  await expect(form.locator('textarea[name=body]')).toHaveValue('Keep this original location');
  await page.getByRole('button', { name: 'Line', exact: true }).click();
  await expect(form.locator('[name=document_id]')).toHaveValue(document);
  await expect(form.locator('[name=start_line]')).toHaveValue('1');
  await expect(form.locator('[name=mode]')).toHaveValue('lexical');
  await page.getByRole('link', { name: 'Discussion', exact: true }).click();
  await expect(header.locator('.structured-toolbar')).toHaveCount(0);
  await expect(header.locator('.breadcrumbs')).toHaveCount(1);
  await page.getByRole('link', { name: 'Changes', exact: true }).click();
  await expect(header.locator('.structured-toolbar')).toHaveCount(1);
  await expect(form.locator('textarea[name=body]')).toHaveValue('Keep this original location');
  await expect(form.locator('[name=document_id]')).toHaveValue(document);
  await page.locator('#inline-composer > summary').click();
  await form.getByRole('button', { name: 'Start discussion', exact: true }).click();
  await expect(page.locator('.mr-discussion .mr-comment').filter({ hasText: 'Keep this original location' })).toBeVisible();
});

async function singlePage(page: Page) {
  await page.goto('/alice/demo/commits?rev=moondiff-single');
  await page.getByRole('row').filter({ hasText: 'MoonDiff single-sided files and declarations' }).getByRole('link').click();
  await expect(page.locator('.structured-diff')).toBeVisible();
}

async function reviewPage(page: Page) {
  await login(page);
  await page.goto('/alice/demo/merge-requests');
  const existing = page.getByRole('link', { name: 'Inline review context', exact: true }).first();
  if (await existing.count()) {
    await existing.click();
    await page.getByRole('link', { name: 'Changes', exact: true }).click();
    return;
  }
  await page.goto('/alice/demo/merge-requests/new');
  await page.getByLabel('Source branch', { exact: true }).selectOption('moondiff-review');
  await page.getByLabel('Target branch', { exact: true }).selectOption('moondiff-review-base');
  await page.getByLabel('Title', { exact: true }).fill('Inline review context');
  await page.getByRole('button', { name: 'Create merge request', exact: true }).click();
  await expect(page).toHaveURL(/\/merge-requests\/\d+$/);
  await page.getByRole('link', { name: 'Changes', exact: true }).click();
}

for (const width of [1440, 390]) for (const layout of ['Split', 'Unified']) test(`inline review keeps code context and highlights ranges in ${layout} at ${width}px`, async ({ page }) => {
  await page.setViewportSize({ width, height: 844 });
  await reviewPage(page);
  await page.getByRole('button', { name: layout, exact: true }).click();
  const file = diffFile(page, 'main.mbt');
  await file.scrollIntoViewIfNeeded();
  const form = page.locator('[data-inline-form]');
  for (const side of ['new', 'old']) {
    const end = file.getByRole('button', { name: `${side} line 95`, exact: true });
    await expect(end).toBeVisible();
    await end.click();
    await expect(form.locator('.CodeMirror-focused')).toBeVisible();
    await expect(end).toBeInViewport();
    await expect(form.locator('.CodeMirror')).toBeInViewport();
    await expect(file.locator('.structured-inline-composer')).toContainText(`${side} L95–95`);
    await expect(end).toHaveAttribute('aria-pressed', 'true');
    // Extend upward, preserving the clicked anchor and original coordinates.
    await file.getByRole('button', { name: `${side} line 93`, exact: true }).click({ modifiers: ['Shift'] });
    await expect(form.locator('[name=start_line]')).toHaveValue('93');
    await expect(form.locator('[name=end_line]')).toHaveValue('95');
    await expect(file.locator(`[data-source-side=${side}][aria-pressed=true]`)).toHaveText(['93', '94', '95']);
    await expect(file.locator(`.diff-source.${side}.is-selected`)).toHaveCount(3);
    await expect(file.locator(`.diff-source.${side}.is-selected`).first()).toHaveCSS('background-color', 'rgb(255, 248, 197)');
    await expect(file.locator(`.diff-source.${side === 'new' ? 'old' : 'new'}.is-selected`)).toHaveCount(0);
    const placement = await file.locator('.structured-inline-composer').evaluate(node => ({
      previous: [...node.closest('tr')!.previousElementSibling!.querySelectorAll('[data-source-side]')].map(button => button.getAttribute('aria-label')),
      top: node.getBoundingClientRect().top,
      lineBottom: node.closest('tr')!.previousElementSibling!.getBoundingClientRect().bottom,
    }));
    expect(placement.previous).toContain(`${side} line 95`);
    expect(placement.top - placement.lineBottom).toBeLessThan(20);
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    await form.getByRole('button', { name: 'Discard draft', exact: true }).click();
    await expect(file.locator('.is-selected')).toHaveCount(0);
    await expect(page.locator('.structured-inline-composer')).toHaveCount(0);
  }
  // Shared Unified context still highlights the code when its old gutter is selected.
  await file.getByRole('button', { name: 'old line 138', exact: true }).click();
  await expect(file.locator('.diff-source.is-selected')).toHaveText('  value134');
  await expect(file.getByRole('button', { name: 'new line 138', exact: true })).toHaveAttribute('aria-pressed', 'false');
  await form.getByRole('button', { name: 'Discard draft', exact: true }).click();
});

test('inline review preserves drafts through layout changes, cancel, mode changes and submission', async ({ page }) => {
  await reviewPage(page);
  const file = diffFile(page, 'main.mbt');
  const line = file.getByRole('button', { name: 'new line 95', exact: true });
  const form = page.locator('[data-inline-form]');
  await line.click();
  await expect(form.locator('.CodeMirror')).toBeVisible();
  await page.keyboard.insertText('Review line 95 beside its code');
  const document = await form.locator('[name=document_id]').inputValue();
  for (const layout of ['Unified', 'Split']) {
    await page.getByRole('button', { name: layout, exact: true }).click();
    await expect(file.locator('.structured-inline-composer')).toBeVisible();
    await expect(form.locator('textarea[name=body]')).toHaveValue('Review line 95 beside its code');
    await expect(form.locator('[name=document_id]')).toHaveValue(document);
    await expect(line).toHaveAttribute('aria-pressed', 'true');
  }
  await form.getByRole('button', { name: 'Cancel', exact: true }).click();
  await expect(page.locator('.structured-inline-composer')).toHaveCount(0);
  await line.click();
  await expect(file.locator('.structured-inline-composer')).toBeVisible();
  await expect(form.locator('.CodeMirror-focused')).toBeVisible();
  await file.getByRole('button', { name: 'new line 94', exact: true }).click();
  await expect(form.locator('[name=start_line]')).toHaveValue('95');
  await expect(line).toHaveAttribute('aria-pressed', 'true');
  await expect(file.locator('.structured-inline-composer')).toContainText('Your draft keeps its original comparison and lines');
  await page.getByRole('button', { name: 'Line', exact: true }).click();
  await expect(page.locator('.structured-inline-composer')).toHaveCount(0);
  await expect(form.locator('[name=document_id]')).toHaveValue(document);
  await expect(form.locator('[name=mode]')).toHaveValue('lexical');
  await expect(form.locator('textarea[name=body]')).toHaveValue('Review line 95 beside its code');
  await form.getByRole('button', { name: 'Start discussion', exact: true }).click();
  await expect(page.locator('.mr-discussion').filter({ hasText: 'Review line 95 beside its code' })).toBeVisible();
});

test('inline review rejects oversized ranges and resets selection across files', async ({ page }) => {
  await reviewPage(page);
  const file = diffFile(page, 'main.mbt');
  const form = page.locator('[data-inline-form]');
  await file.getByRole('button', { name: 'new line 3', exact: true }).click();
  await file.getByRole('button', { name: 'new line 103', exact: true }).click({ modifiers: ['Shift'] });
  await expect(form.locator('[name=start_line]')).toHaveValue('3');
  await expect(form.locator('[name=end_line]')).toHaveValue('3');
  await expect(file.locator('.structured-inline-composer')).toContainText('Select 1–100 consecutive lines');
  const other = diffFile(page, 'other.txt');
  await other.getByRole('button', { name: 'old line 1', exact: true }).click({ modifiers: ['Shift'] });
  await expect(file.locator('.is-selected')).toHaveCount(0);
  await expect(other.locator('.structured-inline-composer')).toBeVisible();
  await expect(form.locator('[name=path]')).toHaveValue('other.txt');
  await expect(form.locator('[name=start_line]')).toHaveValue('1');
  await expect(form.locator('[name=end_line]')).toHaveValue('1');
  await other.getByRole('button', { name: 'old line 1', exact: true }).click();
  await expect(form.locator('.CodeMirror-focused')).toBeVisible();
  await page.keyboard.insertText('Temporary draft');
  await form.getByRole('button', { name: 'Discard draft', exact: true }).click();
  await file.getByRole('button', { name: 'new line 95', exact: true }).click();
  await file.getByRole('button', { name: 'new line 93', exact: true }).click({ modifiers: ['Shift'] });
  await expect(form.locator('.CodeMirror-focused')).toBeVisible();
  await page.keyboard.insertText('Keep the entire range');
  await form.getByRole('button', { name: 'Cancel', exact: true }).click();
  await file.getByRole('button', { name: 'new line 94', exact: true }).click();
  await expect(form.locator('[name=start_line]')).toHaveValue('93');
  await expect(form.locator('[name=end_line]')).toHaveValue('95');
  await expect(form.locator('textarea[name=body]')).toHaveValue('Keep the entire range');
  await form.getByRole('button', { name: 'Discard draft', exact: true }).click();
});

function diffFile(page: Page, path: string) {
  return page.locator('.structured-file').filter({ has: page.locator(':scope > summary', { hasText: new RegExp(`(?:^| · )${path.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}(?: · |$)`) }) });
}

for (const width of [1440, 390]) for (const mode of ['line', 'lexical']) test(`split long lines stay contained and scroll independently at ${width}px in ${mode} mode`, async ({ page }) => {
  await page.setViewportSize({ width, height: 1000 });
  await login(page);
  await page.goto('/alice/demo/commits?rev=moondiff-long-lines');
  const href = await page.getByRole('row').filter({ hasText: 'MoonDiff two-sided long lines' }).getByRole('link').getAttribute('href');
  await page.goto(`${href}?mode=${mode}`);
  await page.getByRole('button', { name: 'Split', exact: true }).click();
  const file = diffFile(page, 'long-lines.mbt');
  const row = file.locator('table.split tr').filter({ has: page.locator('.diff-source.old', { hasText: 'END-before' }) });
  await expect(row.locator('.diff-source.new')).toContainText('END-after');
  await page.getByLabel('Wrap lines', { exact: true }).uncheck();
  await row.scrollIntoViewIfNeeded();
  const geometry = await row.evaluate(row => {
    const old = row.querySelector<HTMLElement>('.diff-source.old > div')!;
    const next = row.querySelector<HTMLElement>('.diff-source.new > div')!;
    const hunk = row.closest<HTMLElement>('.structured-hunk')!;
    const right = next.getBoundingClientRect();
    const painted = document.elementFromPoint(right.left + 10, right.top + 10);
    return {
      oldWidth: old.clientWidth, newWidth: next.clientWidth,
      oldContent: old.scrollWidth, newContent: next.scrollWidth,
      rightCoveredByNew: !!painted && next.contains(painted),
      hunkOverflow: hunk.scrollWidth - hunk.clientWidth,
      pageOverflow: document.documentElement.scrollWidth - innerWidth,
    };
  });
  expect(geometry.oldContent).toBeGreaterThan(geometry.oldWidth * 2);
  expect(geometry.newContent).toBeGreaterThan(geometry.newWidth * 2);
  expect(Math.abs(geometry.oldWidth - geometry.newWidth)).toBeLessThan(2);
  expect(geometry.rightCoveredByNew).toBe(true);
  expect(geometry.hunkOverflow).toBeLessThanOrEqual(1);
  expect(geometry.pageOverflow).toBeLessThanOrEqual(1);
  for (const side of ['old', 'new']) {
    const bar = file.locator(`.structured-scrollbar.${side}`);
    await expect(bar).toBeVisible();
    await bar.evaluate(node => { node.scrollLeft = node.scrollWidth; });
    await expect.poll(() => file.locator('.structured-scroll-block').evaluate((node, side) => parseFloat(node.style.getPropertyValue(`--split-${side}-offset`)), side)).toBeLessThan(0);
    const scrolled = await row.evaluate((row, side) => {
      const viewport = row.querySelector<HTMLElement>(`.diff-source.${side} > div`)!;
      const peer = row.querySelector<HTMLElement>(`.diff-source.${side === 'old' ? 'new' : 'old'} > div`)!;
      const block = row.closest('.structured-scroll-block')!;
      const bar = block.querySelector<HTMLElement>(`.structured-scrollbar.${side}`)!;
      const peerOffset = peer.scrollLeft;
      const walker = document.createTreeWalker(viewport.querySelector('code')!, NodeFilter.SHOW_TEXT);
      let last = walker.nextNode()!;
      for (let node = walker.nextNode(); node; node = walker.nextNode()) last = node;
      const range = document.createRange();
      range.selectNodeContents(last);
      range.setStart(last, Math.max(0, last.textContent!.length - 1));
      const end = range.getBoundingClientRect();
      const bounds = viewport.getBoundingClientRect();
      return { offset: bar.scrollLeft, peerOffset, peerAfter: peer.scrollLeft, endVisible: end.left >= bounds.left && end.right <= bounds.right + 1 };
    }, side);
    expect(scrolled.offset).toBeGreaterThan(0);
    expect(scrolled.peerAfter).toBe(scrolled.peerOffset);
    expect(scrolled.endVisible).toBe(true);
  }
  await page.getByLabel('Wrap lines', { exact: true }).check();
  for (const cell of await row.locator('.diff-source > div').evaluateAll(nodes => nodes.map(node => ({ overflow: node.scrollWidth - node.clientWidth, height: node.querySelector('code')!.getBoundingClientRect().height })))) {
    expect(cell.overflow).toBeLessThanOrEqual(1);
    expect(cell.height).toBeGreaterThan(20);
  }
  await page.getByRole('button', { name: 'Unified', exact: true }).click();
  await expect(file.locator('table.unified')).toContainText('END-before');
  await expect(file.locator('table.unified')).toContainText('END-after');
});

async function blockScrollPage(page: Page, kind: 'commit' | 'MR' = 'commit') {
  await login(page);
  if (kind === 'MR') {
    await page.goto('/alice/demo/merge-requests/new');
    await page.getByLabel('Source branch', { exact: true }).selectOption('moondiff-scroll');
    await page.getByLabel('Target branch', { exact: true }).selectOption('moondiff-scroll-base');
    await page.getByLabel('Title', { exact: true }).fill('Block scrolling review');
    await page.getByRole('button', { name: 'Create merge request', exact: true }).click();
    await expect(page).toHaveURL(/\/merge-requests\/\d+$/);
    await page.getByRole('link', { name: 'Changes', exact: true }).click();
  } else {
    await page.goto('/alice/demo/commits?rev=moondiff-scroll');
    await page.getByRole('row').filter({ hasText: 'MoonDiff block scrolling' }).getByRole('link').click();
  }
  await page.getByRole('button', { name: 'Split', exact: true }).click();
  await page.getByLabel('Wrap lines', { exact: true }).uncheck();
}

for (const width of [1440, 390]) test(`split block scrollbars share offsets across hunks and isolate declarations at ${width}px`, async ({ page }) => {
  await page.setViewportSize({ width, height: 1000 });
  // Current lexical output includes a full declaration in one hunk. Exercise
  // the protocol's multiple-hunk declaration without changing server behavior.
  await page.route('**/diff?*', async route => {
    const response = await route.fetch();
    const result = await response.json();
    if (result.file?.new_path === 'grouped.mbt') for (const section of result.document.sections) {
      section.hunks = section.hunks.flatMap((hunk: { id: string; rows: unknown[] }) => {
        const middle = Math.floor(hunk.rows.length / 2);
        return [{ ...hunk, rows: hunk.rows.slice(0, middle) }, { ...hunk, id: `${hunk.id}:second`, rows: hunk.rows.slice(middle) }];
      });
    }
    await route.fulfill({ response, json: result });
  });
  await blockScrollPage(page);
  const file = diffFile(page, 'grouped.mbt');
  const blocks = file.locator('.structured-scroll-block');
  await expect(blocks).toHaveCount(2);
  const first = blocks.first();
  await expect(first.locator('.structured-hunk')).toHaveCount(2);
  await expect(first.locator('.structured-scrollbars')).toHaveCount(1);
  const old = first.getByRole('region', { name: /Old code horizontal scroll$/ });
  const next = first.getByRole('region', { name: /New code horizontal scroll$/ });
  await expect(old).toBeVisible();
  await expect(next).toBeVisible();
  const initial = await first.locator('.line-number button').evaluateAll(nodes => nodes.map(node => node.getBoundingClientRect().x));
  await old.evaluate(node => { node.scrollLeft = 160; });
  await expect.poll(() => first.locator('.old code').evaluateAll(nodes => nodes.map(node => new DOMMatrix(getComputedStyle(node).transform).m41))).toEqual(
    Array(await first.locator('.old code').count()).fill(-160));
  for (const peer of [first.locator('.new code'), blocks.last().locator('code')]) {
    expect(await peer.evaluateAll(nodes => nodes.every(node => new DOMMatrix(getComputedStyle(node).transform).m41 === 0))).toBe(true);
  }
  expect(await first.locator('.line-number button').evaluateAll(nodes => nodes.map(node => node.getBoundingClientRect().x))).toEqual(initial);
  const geometry = await first.evaluate(node => {
    const last = [...node.querySelectorAll('table')].at(-1)!.getBoundingClientRect();
    return [...node.querySelectorAll<HTMLElement>('.structured-scrollbar')].map(bar => {
      const cell = node.querySelector<HTMLElement>(`.diff-source.${bar.classList.contains('old') ? 'old' : 'new'}`)!.getBoundingClientRect();
      const rect = bar.getBoundingClientRect();
      return { after: rect.top >= last.bottom, left: Math.abs(rect.left - cell.left), width: Math.abs(rect.width - cell.width), max: bar.scrollWidth,
        natural: Math.max(...[...node.querySelectorAll<HTMLElement>(`.${bar.classList.contains('old') ? 'old' : 'new'} code`)].map(code => code.scrollWidth)) };
    });
  });
  for (const bar of geometry) {
    expect(bar.after).toBe(true);
    expect(bar.left).toBeLessThan(2);
    expect(bar.width).toBeLessThan(2);
    expect(bar.max).toBe(bar.natural);
  }
  // Plain text groups by hunk, even though both hunks share a whole section.
  const text = diffFile(page, 'groups.txt');
  await text.scrollIntoViewIfNeeded();
  await expect(text.locator('.structured-scroll-block')).toHaveCount(2);
  await expect(text.locator('.structured-scroll-block').first().locator('.structured-hunk')).toHaveCount(1);
  await text.locator('.structured-scrollbar.new').first().evaluate(node => { node.scrollLeft = 90; });
  await expect.poll(() => text.locator('.structured-scroll-block').first().evaluate(node => node.style.getPropertyValue('--split-new-offset'))).toBe('-90px');
  expect(await text.locator('.structured-scrollbar.new').last().evaluate(node => node.scrollLeft)).toBe(0);
  for (const [path, oldVisible, newVisible] of [['new-only.txt', false, true], ['old-only.txt', true, false], ['short.txt', false, false]] as const) {
    const oneSide = diffFile(page, path);
    await oneSide.scrollIntoViewIfNeeded();
    await expect(oneSide.locator('table.split')).toBeVisible();
    await expect(oneSide.locator('.structured-scrollbar.old')).toBeVisible({ visible: oldVisible });
    await expect(oneSide.locator('.structured-scrollbar.new')).toBeVisible({ visible: newVisible });
  }
  expect(await page.evaluate(() => document.documentElement.scrollWidth - innerWidth)).toBeLessThanOrEqual(1);
});

test('split block scrolling handles wheel, keyboard, collapse, zoom, resize and reset', async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 1000 });
  await blockScrollPage(page);
  const file = diffFile(page, 'grouped.mbt');
  const block = file.locator('.structured-scroll-block').first();
  const old = block.locator('.structured-scrollbar.old');
  const next = block.locator('.structured-scrollbar.new');
  const cell = block.locator('.diff-source.old').first();
  await cell.hover();
  await page.mouse.wheel(120, 0);
  await expect.poll(() => old.evaluate(node => node.scrollLeft)).toBe(120);
  await cell.dispatchEvent('wheel', { deltaY: 80, shiftKey: true });
  await expect.poll(() => old.evaluate(node => node.scrollLeft)).toBe(200);
  expect(await next.evaluate(node => node.scrollLeft)).toBe(0);
  expect(await cell.evaluate(node => [new WheelEvent('wheel', { deltaY: 30, bubbles: true, cancelable: true }), new WheelEvent('wheel', { deltaX: 1, deltaY: 30, bubbles: true, cancelable: true }), new WheelEvent('wheel', { deltaY: 30, ctrlKey: true, bubbles: true, cancelable: true })].map(event => node.dispatchEvent(event)))).toEqual([true, true, true]);
  await next.focus();
  await next.press('ArrowRight');
  await expect.poll(() => next.evaluate(node => node.scrollLeft)).toBeGreaterThan(0);
  const declaration = file.locator('.structured-declaration').first();
  await declaration.locator(':scope > summary').click();
  await expect(old).toBeHidden();
  await declaration.locator(':scope > summary').click();
  await expect(old).toBeVisible();
  await expect.poll(() => old.evaluate(node => node.scrollLeft)).toBe(200);
  await file.locator(':scope > summary').click();
  await expect(old).toBeHidden();
  await file.locator(':scope > summary').click();
  await expect.poll(() => old.evaluate(node => node.scrollLeft)).toBe(200);
  await page.evaluate(() => { document.documentElement.style.zoom = '1.25'; });
  await expect.poll(() => old.evaluate(node => node.scrollLeft)).toBe(200);
  await expect.poll(() => old.evaluate(node => Math.abs(node.clientWidth - node.closest('.structured-scroll-block')!.querySelector('.diff-source.old')!.clientWidth))).toBeLessThan(2);
  await page.evaluate(() => { document.documentElement.style.zoom = ''; });
  await old.evaluate(node => { node.scrollLeft = node.scrollWidth; });
  await page.setViewportSize({ width: 1800, height: 1000 });
  await expect.poll(() => old.evaluate(node => node.scrollLeft - (node.scrollWidth - node.clientWidth))).toBe(0);
  await expect.poll(() => block.evaluate(node => parseFloat(node.style.getPropertyValue('--split-old-offset')))).toBe(await old.evaluate(node => -node.scrollLeft));
  await page.getByLabel('Wrap lines', { exact: true }).check();
  await expect(old).toBeHidden();
  await page.getByLabel('Wrap lines', { exact: true }).uncheck();
  await expect.poll(() => old.evaluate(node => node.scrollLeft)).toBe(0);
  await old.evaluate(node => { node.scrollLeft = 100; });
  await page.getByRole('button', { name: 'Unified', exact: true }).click();
  await expect(file.locator('.structured-scroll-block')).toHaveCount(0);
  await page.getByRole('button', { name: 'Split', exact: true }).click();
  await expect.poll(() => old.evaluate(node => node.scrollLeft)).toBe(0);
  await old.evaluate(node => { node.scrollLeft = 100; });
  await page.getByRole('button', { name: 'AST', exact: true }).click();
  await expect.poll(() => old.evaluate(node => node.scrollLeft)).toBe(0);
});

test('split block scrolling handles a horizontal touch swipe while preserving vertical scrolling', async ({ browser }) => {
  const context = await browser.newContext({ viewport: { width: 390, height: 844 }, hasTouch: true, isMobile: true });
  const page = await context.newPage();
  try {
    await blockScrollPage(page);
    const block = diffFile(page, 'grouped.mbt').locator('.structured-scroll-block').first();
    const cell = block.locator('.diff-source.new').first();
    await cell.scrollIntoViewIfNeeded();
    const box = (await cell.boundingBox())!;
    const session = await context.newCDPSession(page);
    const x = box.x + box.width - 8, y = box.y + 10;
    await session.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x, y }] });
    for (let step = 1; step <= 5; step++) await session.send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: [{ x: x - step * 8, y }] });
    await session.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
    const next = block.locator('.structured-scrollbar.new');
    await expect.poll(() => next.evaluate(node => node.scrollLeft)).toBeGreaterThan(20);
    expect(await block.locator('.structured-scrollbar.old').evaluate(node => node.scrollLeft)).toBe(0);
    await cell.scrollIntoViewIfNeeded();
    const verticalBox = (await cell.boundingBox())!;
    const before = await page.evaluate(() => scrollY);
    await session.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x, y: verticalBox.y + 10 }] });
    for (let step = 1; step <= 5; step++) await session.send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: [{ x, y: verticalBox.y + 10 - step * 10 }] });
    await session.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
    await expect.poll(() => page.evaluate(() => scrollY)).toBeGreaterThan(before);
    await session.detach();
  } finally { await context.close(); }
});

test('split client preserves scrolled selection, editor placement and draft coordinates', async ({ page }) => {
  await blockScrollPage(page);
  // Exercise the shared comment controller independently of MR creation, which
  // requires merge-tree --write-tree on the fixture server's Git installation.
  await page.evaluate(() => {
    const host = document.querySelector('moonhub-structured-diff')!;
    const composer = document.createElement('details');
    composer.id = 'inline-composer';
    const form = document.createElement('form');
    form.dataset.inlineForm = '';
    for (const name of ['document_id', 'file_id', 'hunk_id', 'diff_page', 'mode', 'ignore_comments', 'ignore_tests', 'path', 'side', 'start_line', 'end_line']) {
      const field = document.createElement('input'); field.type = 'hidden'; field.name = name; form.append(field);
    }
    const body = document.createElement('textarea'); body.name = 'body'; form.append(body);
    composer.append(document.createElement('summary'), form); host.before(composer);
    const replacement = document.createElement('moonhub-structured-diff');
    for (const attribute of host.attributes) replacement.setAttribute(attribute.name, attribute.value);
    host.replaceWith(replacement);
  });
  await page.getByLabel('Wrap lines', { exact: true }).uncheck();
  const file = diffFile(page, 'grouped.mbt');
  const block = file.locator('.structured-scroll-block').first();
  const bar = block.locator('.structured-scrollbar.new');
  await expect(bar).toBeVisible();
  await bar.evaluate(node => { node.scrollLeft = 180; });
  await file.getByRole('button', { name: 'new line 3', exact: true }).click();
  await file.getByRole('button', { name: 'new line 4', exact: true }).click({ modifiers: ['Shift'] });
  const form = page.locator('[data-inline-form]');
  await expect(form.locator('[name=start_line]')).toHaveValue('3');
  await expect(form.locator('[name=end_line]')).toHaveValue('4');
  await expect(file.locator('.diff-source.new.is-selected')).toHaveCount(2);
  const editor = file.locator('.structured-inline-composer');
  expect(await editor.evaluate(node => ({ span: node.closest('td')!.colSpan, transform: getComputedStyle(node).transform, overflow: node.getBoundingClientRect().right > innerWidth }))).toEqual({ span: 4, transform: 'none', overflow: false });
  await expect.poll(() => bar.evaluate(node => node.scrollLeft)).toBe(180);
  await form.locator('textarea').fill('Draft at a scrolled location');
  const coordinates = await form.evaluate(node => Object.fromEntries(new FormData(node as HTMLFormElement)));
  await page.getByLabel('Wrap lines', { exact: true }).check();
  await page.getByRole('button', { name: 'Unified', exact: true }).click();
  await expect(form.locator('textarea')).toHaveValue('Draft at a scrolled location');
  await page.getByRole('button', { name: 'Split', exact: true }).click();
  await file.getByRole('button', { name: 'old line 5', exact: true }).click();
  await expect(editor).toContainText('Your draft keeps its original comparison and lines');
  expect(await form.evaluate(node => Object.fromEntries(new FormData(node as HTMLFormElement)))).toEqual(coordinates);
  await page.getByRole('button', { name: 'Line', exact: true }).click();
  await expect(file.locator('.structured-inline-composer')).toHaveCount(0);
  expect(await form.evaluate(node => Object.fromEntries(new FormData(node as HTMLFormElement)))).toEqual(coordinates);
  await page.evaluate(() => {
    const host = document.querySelector('moonhub-structured-diff')!;
    const manifest = JSON.parse(host.getAttribute('data-manifest')!);
    const discussion = document.createElement('div');
    discussion.id = 'discussion-scroll-fixture'; discussion.dataset.discussionAnchor = '';
    discussion.dataset.anchor = JSON.stringify({ base_sha: manifest.base_sha, head_sha: manifest.head_sha, new_path: 'grouped.mbt', old_path: 'grouped.mbt', side: 'new', start_line: 3, end_line: 4, context: 'Scrolled code discussion' });
    host.after(discussion);
    const url = new URL(location.href); url.searchParams.set('code', 'scroll-fixture'); history.replaceState(history.state, '', url);
    const replacement = document.createElement('moonhub-structured-diff');
    for (const attribute of host.attributes) replacement.setAttribute(attribute.name, attribute.value);
    host.replaceWith(replacement);
  });
  await expect(file.getByRole('link', { name: 'Discussion: new L3–4', exact: true })).toBeVisible();
  await expect(file.getByRole('button', { name: 'new line 4', exact: true })).toBeInViewport();
});

test('MR split block scroll keeps line selection, spanning editor, drafts and discussion coordinates', async ({ page }) => {
  await blockScrollPage(page, 'MR');
  const file = diffFile(page, 'grouped.mbt');
  const block = file.locator('.structured-scroll-block').first();
  const bar = block.locator('.structured-scrollbar.new');
  await bar.evaluate(node => { node.scrollLeft = 180; });
  await file.getByRole('button', { name: 'new line 3', exact: true }).click();
  await file.getByRole('button', { name: 'new line 4', exact: true }).click({ modifiers: ['Shift'] });
  const form = page.locator('[data-inline-form]');
  await expect(form.locator('[name=start_line]')).toHaveValue('3');
  await expect(form.locator('[name=end_line]')).toHaveValue('4');
  await expect(file.locator('.diff-source.new.is-selected')).toHaveCount(2);
  const editor = file.locator('.structured-inline-composer');
  expect(await editor.evaluate(node => ({ span: node.closest('td')!.colSpan, transform: getComputedStyle(node).transform, overflow: node.getBoundingClientRect().right > innerWidth }))).toEqual({ span: 4, transform: 'none', overflow: false });
  await expect.poll(() => bar.evaluate(node => node.scrollLeft)).toBe(180);
  await page.keyboard.insertText('Review the horizontally scrolled range');
  const documentId = await form.locator('[name=document_id]').inputValue();
  await page.getByLabel('Wrap lines', { exact: true }).check();
  await page.getByRole('button', { name: 'Unified', exact: true }).click();
  await expect(form.locator('[name=document_id]')).toHaveValue(documentId);
  await expect(form.locator('textarea[name=body]')).toHaveValue('Review the horizontally scrolled range');
  await form.getByRole('button', { name: 'Start discussion', exact: true }).click();
  const discussion = page.locator('.mr-discussion').filter({ hasText: 'Review the horizontally scrolled range' });
  await expect(discussion).toBeVisible();
  const url = new URL(page.url());
  url.searchParams.set('tab', 'changes');
  url.searchParams.set('code', (await discussion.getAttribute('id'))!.replace('discussion-', ''));
  await page.goto(url.href);
  await expect(file.getByRole('button', { name: 'new line 4', exact: true })).toBeInViewport();
});

for (const width of [1440, 390]) for (const mode of ['line', 'lexical', 'ast']) test(`unified context appears once with both source coordinates at ${width}px in ${mode} mode`, async ({ page }) => {
  await page.setViewportSize({ width, height: 1000 });
  await login(page);
  await page.goto('/alice/demo/commits?rev=moondiff-long-lines');
  const href = await page.getByRole('row').filter({ hasText: 'MoonDiff two-sided long lines' }).getByRole('link').getAttribute('href');
  await page.goto(`${href}?mode=${mode}`);
  await page.getByRole('button', { name: 'Unified', exact: true }).click();
  const file = diffFile(page, 'long-lines.mbt');
  const table = file.locator('table.unified');
  const before = `  let message = "${'before long message '.repeat(20)}END-before"`;
  const after = `  let message = "${'after long message '.repeat(20)}END-after"`;
  await expect(table.locator('code')).toHaveText(['///|', 'fn greeting(name : String) -> String {', before, after, '  message + name', '}']);
  await expect(table.locator('tr')).toHaveCount(6);
  expect(await table.locator('tr').evaluateAll(rows => rows.map(row => [...row.querySelectorAll('.line-number')].map(cell => cell.textContent)))).toEqual([
    ['1', '1'], ['2', '2'], ['3', ''], ['', '3'], ['4', '4'], ['5', '5'],
  ]);
  for (const side of ['old', 'new']) {
    await expect(table.getByRole('button', { name: `${side} line 4`, exact: true })).toHaveAttribute('data-source-side', side);
  }
  await expect(table.locator('.diff-source.change.old')).toHaveText(before);
  await expect(table.locator('.diff-source.change.new')).toHaveText(after);
  await expect(table.locator('.diff-source.context .segment-changed')).toHaveCount(0);
  await expect.poll(() => table.locator('code span[style]').count()).toBeGreaterThan(0);
  expect(await page.evaluate(() => document.documentElement.scrollWidth - innerWidth)).toBeLessThanOrEqual(1);
  await page.getByRole('button', { name: 'Split', exact: true }).click();
  await expect(file.locator('table.split tr')).toHaveCount(5);
  await expect(file.locator('table.split code')).toHaveCount(10);
  await page.getByRole('button', { name: 'Unified', exact: true }).click();
  await expect(table.locator('code')).toHaveText(['///|', 'fn greeting(name : String) -> String {', before, after, '  message + name', '}']);
});

test('unified context retains shifted old and new line numbers after insertions', async ({ page }) => {
  await login(page);
  await page.goto('/alice/demo/commits?rev=moondiff-long-lines');
  await page.getByRole('row').filter({ hasText: 'MoonDiff two-sided long lines' }).getByRole('link').click();
  await page.getByRole('button', { name: 'Unified', exact: true }).click();
  const file = diffFile(page, 'shifted.txt');
  await file.scrollIntoViewIfNeeded();
  const table = file.locator('table.unified');
  await expect(table.locator('code')).toHaveText(['shared header', 'remove me', 'insert one', 'insert two', 'shared middle', 'shared tail']);
  for (const [text, oldNumber, newNumber] of [['shared middle', 3, 4], ['shared tail', 4, 5]] as const) {
    const row = table.locator('tr').filter({ has: page.locator('code', { hasText: text }) });
    await expect(row.locator('.line-number')).toHaveText([String(oldNumber), String(newNumber)]);
    await expect(row.getByRole('button', { name: `old line ${oldNumber}`, exact: true })).toHaveAttribute('data-source-line', String(oldNumber));
    await expect(row.getByRole('button', { name: `new line ${newNumber}`, exact: true })).toHaveAttribute('data-source-line', String(newNumber));
  }
});

for (const mode of ['lexical', 'ast']) test(`unified ignored comments merge identical text and preserve differences in ${mode} mode`, async ({ page }) => {
  await login(page);
  await page.goto('/alice/demo/commits?rev=moondiff-long-lines');
  const href = await page.getByRole('row').filter({ hasText: 'MoonDiff two-sided long lines' }).getByRole('link').getAttribute('href');
  await page.goto(`${href}?mode=${mode}`);
  await page.getByRole('button', { name: 'Unified', exact: true }).click();
  const file = diffFile(page, 'ignored.mbt');
  await file.scrollIntoViewIfNeeded();
  const table = file.locator('table.unified');
  await expect(table.locator('.diff-source.ignored code')).toHaveText(['///|', '// before comment', '// after comment']);
  const separator = table.locator('tr').filter({ has: page.locator('code', { hasText: /^\/\/\/\|$/ }) });
  await expect(separator.locator('.line-number')).toHaveText(['1', '1']);
  await expect(table.locator('.diff-source.ignored.old')).toHaveText('// before comment');
  await expect(table.locator('.diff-source.ignored.new').filter({ hasText: '// after comment' })).toHaveCount(1);
});

async function syntaxPage(page: Page) {
  await page.goto('/alice/demo/commits?rev=moondiff-syntax');
  const href = await page.getByRole('row').filter({ hasText: 'Syntax highlighting languages' }).getByRole('link').getAttribute('href');
  await page.goto(`${href}?mode=line`);
  await expect(page.locator('.structured-diff')).toBeVisible();
}

async function syntaxColors(page: Page, path: string, needles: string[]) {
  return diffFile(page, path).locator('.diff-source.new code').evaluateAll((codes, needles) => needles.map(needle => {
    const code = codes.find(code => code.textContent!.includes(needle));
    if (!code) return '';
    let offset = code.textContent!.indexOf(needle);
    const walker = document.createTreeWalker(code, NodeFilter.SHOW_TEXT);
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      if (offset < node.textContent!.length) return node.parentElement!.closest('span[style]') ? getComputedStyle(node.parentElement!).color : '';
      offset -= node.textContent!.length;
    }
    return '';
  }), needles);
}

test('structured diffs color supported languages and retain unknown and plain text', async ({ page }) => {
  const errors: string[] = [];
  page.on('pageerror', error => errors.push(error.message));
  const javascriptImports: string[] = [];
  page.on('request', request => { if (/\/assets\/javascript-[^/]+\.mjs$/.test(request.url())) javascriptImports.push(request.url()); });
  await login(page);
  await syntaxPage(page);
  for (const [path, needles] of [
    ['another.js', ['const', '"after"', '// after comment']],
    ['sample.js', ['const', '"after"', '// after comment']],
    ['sample.ts', ['const', '"after"', '// after comment']],
    ['sample.tsx', ['const', '"after"', '// after comment']],
    ['sample.json', ['true', '"after"']],
    ['sample.yaml', ['true', '"after"', '# after comment']],
    ['sample.py', ['return', '"after"', '# after comment']],
    ['sample.sh', ['if', '"after"', '# after comment']],
    ['sample.mbt', ['fn', '"after"', '// after comment']],
    ['sample.mbti', ['pub', '// after comment']],
  ] as const) {
    const file = diffFile(page, path);
    await file.scrollIntoViewIfNeeded();
    await expect.poll(async () => {
      const colors = await syntaxColors(page, path, [...needles]);
      return colors.every(Boolean) ? new Set(colors).size : 0;
    }, { message: `distinct syntax colors for ${path}` }).toBe(needles.length);
    await expect(file.locator('.diff-source.old')).toContainText([/before/]);
    await expect(file.locator('.diff-source.new')).toContainText([/after/]);
  }
  expect(javascriptImports).toHaveLength(1);
  for (const path of ['sample.unknown', 'sample.txt']) {
    const file = diffFile(page, path);
    await file.scrollIntoViewIfNeeded();
    await expect(file.locator('.diff-source.new code')).toHaveText(['// after comment', 'const message = "after";']);
    await expect(file.locator('code span[style]')).toHaveCount(0);
  }
  expect(errors).toEqual([]);
});

for (const failure of ['import', 'registration'] as const) test(`failed grammar ${failure} leaves original diff text readable`, async ({ page }) => {
  const errors: string[] = [];
  page.on('pageerror', error => errors.push(error.message));
  let imports = 0;
  await page.route('**/assets/javascript-*.mjs', async route => {
    imports++;
    if (failure === 'import') await route.abort();
    else await route.fulfill({ contentType: 'text/javascript', body: 'export default [];' });
  });
  await login(page);
  await syntaxPage(page);
  for (const path of ['another.js', 'sample.js']) {
    const file = diffFile(page, path);
    await file.scrollIntoViewIfNeeded();
    await expect(file.locator('.diff-source.new code')).toHaveText(['// after comment', 'const message = "after";']);
  }
  await expect.poll(() => imports).toBeGreaterThan(0);
  await expect(diffFile(page, 'sample.js').locator('code span[style]')).toHaveCount(0);
  await page.getByRole('button', { name: 'Token', exact: true }).click();
  await expect(page.getByRole('button', { name: 'Token', exact: true })).toHaveAttribute('aria-pressed', 'true');
  await diffFile(page, 'sample.js').scrollIntoViewIfNeeded();
  await expect(diffFile(page, 'sample.js').locator('.diff-source.new')).toContainText([/const message = "after";/]);
  expect(errors).toEqual([]);
});

for (const action of ['mode', 'navigate'] as const) test(`delayed grammar imports tolerate ${action} changes`, async ({ page }) => {
  const errors: string[] = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.addInitScript(() => {
    const terminated = new WeakSet<Worker>();
    const terminate = Worker.prototype.terminate;
    const postMessage = Worker.prototype.postMessage;
    (window as any).obsoleteHighlightPosts = 0;
    Worker.prototype.terminate = function () { terminated.add(this); terminate.call(this); };
    Worker.prototype.postMessage = function (message: unknown, options?: Transferable[] | StructuredSerializeOptions) {
      if (terminated.has(this)) (window as any).obsoleteHighlightPosts++;
      postMessage.call(this, message, Array.isArray(options) ? { transfer: options } : options);
    };
  });
  let release!: () => void;
  const gate = new Promise<void>(resolve => { release = resolve; });
  let started = false;
  await page.route('**/assets/javascript-*.mjs', async route => {
    started = true;
    await gate;
    await route.continue();
  });
  await login(page);
  await syntaxPage(page);
  await expect.poll(() => started).toBe(true);
  const file = diffFile(page, 'another.js');
  await expect(file.locator('.diff-source.new code')).toHaveText(['// after comment', 'const message = "after";']);
  if (action === 'mode') {
    await page.getByRole('button', { name: 'Token', exact: true }).click();
    await expect(page.getByRole('button', { name: 'Token', exact: true })).toHaveAttribute('aria-pressed', 'true');
    await expect(file.locator('.diff-source.new')).toContainText([/const message = "after";/]);
  } else {
    await page.getByRole('link', { name: 'Files', exact: true }).first().click();
    await expect(page.locator('.structured-diff')).toHaveCount(0);
  }
  release();
  if (action === 'navigate') {
    await page.goBack();
    await expect(page.locator('.structured-diff')).toBeVisible();
  }
  await expect.poll(async () => new Set(await syntaxColors(page, 'another.js', ['const', '"after"'])).size).toBe(2);
  await expect(page.getByRole('button', { name: action === 'mode' ? 'Token' : 'Line', exact: true })).toHaveAttribute('aria-pressed', 'true');
  expect(await page.evaluate(() => (window as any).obsoleteHighlightPosts)).toBe(0);
  expect(errors).toEqual([]);
});

for (const width of [1440, 390]) test(`one-sided files and declarations fill the diff at ${width}px in both layouts`, async ({ page }) => {
  await page.setViewportSize({ width, height: 1000 });
  await login(page);
  await singlePage(page);
  for (const layout of ['split', 'unified']) {
    const toggle = page.getByRole('button', { name: layout === 'split' ? 'Split' : 'Unified', exact: true });
    await toggle.click();
    await expect(toggle).toHaveAttribute('aria-pressed', 'true');
    for (const [path, side] of [['added.mbt', 'new'], ['added.txt', 'new'], ['deleted.mbt', 'old'], ['deleted.txt', 'old'], ['blank-added.txt', 'new']]) {
      const file = diffFile(page, path);
      await file.scrollIntoViewIfNeeded();
      await expect(file.locator('table').first()).toHaveClass(`single-side ${side}`);
      await expect(file.locator('summary')).toHaveText(path);
      await expect(file.locator('.structured-declaration, .structured-metadata')).toHaveCount(0);
      await expect(file).not.toContainText(/∅|Changes|Fallback:|Mode:|Line endings:|Final newline:|Declaration order changed/);
      const rows = await file.locator('tr').evaluateAll(nodes => nodes.map(row => {
        const cells = [...row.querySelectorAll('td')];
        return { count: cells.length, colors: cells.map(cell => getComputedStyle(cell).backgroundColor), width: row.getBoundingClientRect().width, table: row.closest('table')!.parentElement!.getBoundingClientRect().width };
      }));
      expect(rows.length).toBeGreaterThan(0);
      for (const row of rows) {
        expect(row.count).toBe(2);
        expect(row.colors).toEqual(Array(2).fill(side === 'new' ? 'rgb(218, 251, 225)' : 'rgb(255, 235, 233)'));
        expect(Math.abs(row.width - row.table)).toBeLessThan(2);
      }
      for (const color of await file.locator('.segment-changed').evaluateAll(nodes => nodes.map(node => getComputedStyle(node).backgroundColor))) expect(color).toBe('rgba(0, 0, 0, 0)');
    }
    const declarations = diffFile(page, 'declarations.mbt');
    await declarations.scrollIntoViewIfNeeded();
    await expect(declarations.locator('table.single-side.old')).toContainText('struct Removed');
    await expect(declarations.locator('table.single-side.new')).toContainText('enum Added');
    await expect(declarations.locator('.structured-declaration')).toHaveCount(0);
    const metadata = diffFile(page, 'metadata.txt');
    await metadata.scrollIntoViewIfNeeded();
    await expect(metadata).toContainText('Mode: 100644 → 100755');
    await expect(metadata).toContainText('Line endings: crlf → lf');
    await expect(metadata).toContainText('Final newline: true → false');
    await expect(metadata.locator(`table.${layout}`)).toBeVisible();
  }
  // Syntax color survives removal of character-level backgrounds.
  const added = diffFile(page, 'added.mbt');
  await expect(added.locator('code span[style]').first()).toHaveAttribute('style', /color:/);
  await page.getByLabel('Wrap lines', { exact: true }).uncheck();
  const long = diffFile(page, 'added.txt');
  expect(await long.locator('.structured-hunk').evaluate(node => node.scrollWidth > node.clientWidth)).toBe(true);
  for (const path of ['empty-added.txt']) {
    const file = diffFile(page, path);
    await file.scrollIntoViewIfNeeded();
    await expect(file.locator('[role=status]')).toHaveCount(0);
    await expect(file.locator('summary')).toHaveText(path);
    await expect(file.locator('table, .structured-declaration, .structured-metadata')).toHaveCount(0);
  }
  const filtered = diffFile(page, 'added_test.mbt');
  await filtered.scrollIntoViewIfNeeded();
  await expect(filtered).toContainText('Filtered:');
  await expect(filtered.locator('table')).toHaveCount(0);
  await page.getByLabel('Ignore tests', { exact: true }).uncheck();
  await expect(filtered.locator('table.single-side.new')).toContainText('assert_true');
  await page.getByRole('button', { name: 'Next change', exact: true }).click();
  await expect(page.locator('[data-change]:focus')).toHaveCount(1);
  await page.getByRole('button', { name: 'Previous change', exact: true }).click();
  await expect(page.locator('[data-change]:focus')).toHaveCount(1);
});

test('one-sided file loading errors keep a retry action', async ({ page }) => {
  await login(page);
  let fail = true;
  await page.route('**/commit/*/diff?*', async route => {
    if (fail) await route.fulfill({ status: 503, body: 'temporarily unavailable' });
    else await route.continue();
  });
  await singlePage(page);
  const added = diffFile(page, 'added.mbt');
  await added.scrollIntoViewIfNeeded();
  await expect(added.getByRole('alert')).toContainText('Unable to load this file');
  await expect(added.locator('summary')).toHaveText('added.mbt');
  fail = false;
  await added.getByRole('button', { name: 'Retry file' }).click();
  await expect(added.locator('table.single-side.new').first()).toBeVisible();
  await expect(added.getByRole('alert')).toHaveCount(0);
});

test('one-sided files and declarations remain clean without JavaScript', async ({ page, browser }) => {
  await login(page);
  await singlePage(page);
  const url = new URL(page.url());
  const manifest = JSON.parse((await page.locator('moonhub-structured-diff').getAttribute('data-manifest'))!);
  const context = await browser.newContext({ javaScriptEnabled: false, storageState: await page.context().storageState() });
  const native = await context.newPage();
  for (const path of ['added.mbt', 'added.txt', 'deleted.mbt', 'deleted.txt', 'declarations.mbt', 'empty-added.txt', 'blank-added.txt', 'added_test.mbt', 'metadata.txt']) {
    const file = manifest.files.find((file: { old_path: string; new_path: string }) => (file.new_path || file.old_path) === path);
    url.searchParams.set('file_id', file.id);
    await native.goto(url.href);
    const selected = native.locator('[data-diff-fallback] > section');
    await expect(selected.getByRole('heading')).toHaveText(path);
    if (path === 'metadata.txt') {
      await expect(selected).toContainText('Mode: 100644 → 100755');
      await expect(selected).toContainText('Line endings: crlf → lf');
      await expect(selected).toContainText('Final newline: true → false');
    } else {
      await expect(selected.locator('details')).toHaveCount(0);
      await expect(selected).not.toContainText(/∅|Changes|Fallback:|Mode:|Line endings:|Final newline:|Declaration order changed/);
      if (path === 'declarations.mbt') {
        await expect(selected.locator('table.single-side.old')).toContainText('struct Removed');
        await expect(selected.locator('table.single-side.new')).toContainText('enum Added');
      } else if (path === 'added_test.mbt') await expect(selected).toContainText('Filtered:');
      else if (path.startsWith('empty-')) await expect(selected.locator('table')).toHaveCount(0);
      else await expect(selected.locator('table.single-side').first()).toBeVisible();
    }
  }
  await context.close();
});

test('deleted empty files have only a filename with and without JavaScript', async ({ page, browser }) => {
  await login(page);
  await page.goto('/alice/demo/commits?rev=moondiff-empty-delete');
  await page.getByRole('row').filter({ hasText: 'MoonDiff deleted empty file' }).getByRole('link').click();
  const file = diffFile(page, 'empty-added.txt');
  await expect(file.locator('summary')).toHaveText('empty-added.txt');
  await expect(file.locator('[role=status]')).toHaveCount(0);
  await expect(file.locator('table, .structured-declaration, .structured-metadata')).toHaveCount(0);
  const manifest = JSON.parse((await page.locator('moonhub-structured-diff').getAttribute('data-manifest'))!);
  expect(manifest.files[0].status).toBe('D');
  const url = new URL(page.url()); url.searchParams.set('file_id', manifest.files[0].id);
  const context = await browser.newContext({ javaScriptEnabled: false, storageState: await page.context().storageState() });
  const native = await context.newPage();
  await native.goto(url.href);
  const selected = native.locator('[data-diff-fallback] > section');
  await expect(selected).toHaveText('empty-added.txt');
  await context.close();
});

test('one-sided line selection keeps original coordinates and opens saved discussions', async ({ page }) => {
  await login(page);
  await page.goto('/alice/demo/merge-requests/new');
  await page.getByLabel('Source branch', { exact: true }).selectOption('moondiff-single');
  await page.getByLabel('Target branch', { exact: true }).selectOption('moondiff-single-base');
  await page.getByLabel('Title', { exact: true }).fill('One-sided browser review');
  await page.getByRole('button', { name: 'Create merge request', exact: true }).click();
  await page.getByRole('link', { name: 'Changes', exact: true }).click();
  const form = page.locator('[data-inline-form]');
  for (const [path, side, first, last] of [['added.mbt', 'new', 1, 1], ['deleted.txt', 'old', 1, 3], ['declarations.mbt', 'old', 4, 6], ['declarations.mbt', 'new', 4, 6]] as const) {
    const file = diffFile(page, path);
    await file.scrollIntoViewIfNeeded();
    await file.getByRole('button', { name: `${side} line ${first}`, exact: true }).click();
    await file.getByRole('button', { name: `${side} line ${last}`, exact: true }).click({ modifiers: ['Shift'] });
    await expect(form.locator('[name=path]')).toHaveValue(path);
    await expect(form.locator('[name=side]')).toHaveValue(side);
    await expect(form.locator('[name=start_line]')).toHaveValue(String(first));
    await expect(form.locator('[name=end_line]')).toHaveValue(String(last));
    await expect(file.locator('.structured-inline-composer')).toBeVisible();
    await expect(file.locator(`.diff-source.${side}.is-selected`)).toHaveCount(last - first + 1);
    await expect(file.locator(`.diff-source.${side}.is-selected`).first()).toHaveCSS('background-color', 'rgb(255, 248, 197)');
    await expect(form.locator('[name=document_id]')).toHaveValue(/[a-f0-9]{64}/);
    const hunk = await file.locator(`table.single-side.${side}`).first().locator('..').getAttribute('data-hunk');
    await expect(form.locator('[name=hunk_id]')).toHaveValue(hunk!);
  }
  await form.locator('.CodeMirror').click();
  await page.keyboard.insertText('Comment on an inserted declaration');
  await form.getByRole('button', { name: 'Start discussion', exact: true }).click();
  const discussion = page.locator('.mr-discussion').filter({ hasText: 'Comment on an inserted declaration' });
  await expect(discussion).toBeVisible();
  const id = await discussion.getAttribute('id');
  const url = new URL(page.url());
  url.searchParams.set('tab', 'changes');
  url.searchParams.set('code', id!.replace('discussion-', ''));
  await page.goto(url.href);
  const file = diffFile(page, 'declarations.mbt');
  await expect(file.getByRole('button', { name: 'new line 6', exact: true })).toBeInViewport();
});


test('commit header stays usable on narrow screens and retains the account menu', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 900 });
  await login(page);
  await commitPage(page);
  const header = page.locator('.site-header');
  await expect(header.locator('.structured-toolbar')).toHaveCount(1);
  const layout = header.getByRole('group', { name: 'Diff layout', exact: true });
  await expect(layout.getByRole('button', { name: 'Unified', exact: true })).toHaveAttribute('aria-pressed', 'true');
  await layout.getByRole('button', { name: 'Split', exact: true }).click();
  await expect(layout.getByRole('button', { name: 'Split', exact: true })).toHaveAttribute('aria-pressed', 'true');
  await expect(header.getByLabel('Account menu', { exact: true })).toBeInViewport();
  await expect(header.getByRole('link', { name: 'moonhub home' })).toBeInViewport();
  expect(await header.locator('moonhub-diff-toolbar').evaluate(node => node.scrollWidth > node.clientWidth)).toBe(true);
  await header.getByRole('button', { name: 'Next change', exact: true }).click();
  await expect(page.locator('[data-change]:focus')).toHaveCount(1);
  await expect(header.getByLabel('Account menu', { exact: true })).toBeInViewport();
  await header.getByRole('button', { name: 'AST', exact: true }).click();
  await expect(header.getByRole('button', { name: 'AST', exact: true })).toHaveAttribute('aria-pressed', 'true');
  await header.getByLabel('Account menu', { exact: true }).click();
  await expect(header.getByRole('link', { name: 'Profile', exact: true })).toBeVisible();
  await page.keyboard.press('Escape');
  const navigation = page.getByRole('button', { name: 'Open navigation', exact: true });
  await expect(navigation).toBeVisible();
  await navigation.click();
  await expect(page.locator('#app-sidebar')).toHaveAttribute('aria-modal', 'true');
  await page.keyboard.press('Escape');
  await expect(page.locator('#app-sidebar')).not.toHaveAttribute('aria-modal', 'true');
  await expect(header.getByLabel('Account menu', { exact: true })).toBeInViewport();
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
});

test('byte-only paths stay isolated and later-page comments survive source links, refresh and no JavaScript', async ({ page, browser }) => {
  await login(page);
  await page.goto('/alice/demo/merge-requests/new');
  await page.getByLabel('Source branch', { exact: true }).selectOption('moondiff-paged');
  await page.getByLabel('Target branch', { exact: true }).selectOption('moondiff-paged-base');
  await page.getByLabel('Title', { exact: true }).fill('Paged byte paths');
  await page.getByRole('button', { name: 'Create merge request', exact: true }).click();
  await expect(page).toHaveURL(/\/merge-requests\/\d+$/);
  const mrURL = page.url();
  const fileRequests: string[] = [];
  page.on('request', request => {
    const url = new URL(request.url());
    if (url.pathname.endsWith('/diff') && url.searchParams.has('file_id')) fileRequests.push(url.searchParams.get('file_id')!);
  });
  await page.getByRole('link', { name: 'Changes', exact: true }).click();
  const manifest = JSON.parse((await page.locator('moonhub-structured-diff').getAttribute('data-manifest'))!);
  const invalid = manifest.files.filter((f: { path_error?: string }) => f.path_error);
  expect(invalid).toHaveLength(2);
  for (const file of invalid) {
    const view = page.locator(`#diff-file-${file.id}`);
    await expect(view.getByRole('alert')).toContainText('non-UTF-8 path');
    await expect(view.getByRole('button', { name: 'Retry file' })).toHaveCount(0);
    await expect(view.locator('[data-source-line]')).toHaveCount(0);
    expect(fileRequests).not.toContain(file.id);
  }
  const valid = manifest.files.find((f: { new_path: string; path_error?: string }) => f.new_path === '"bad-\\xff"' && !f.path_error);
  expect(valid).toBeTruthy();
  expect(invalid.some((f: { id: string; new_path: string }) => f.new_path === valid.new_path && f.id !== valid.id)).toBe(true);
  await page.getByRole('link', { name: 'Next files', exact: true }).click();
  await expectFilePage(page, 2);
  const file = diffFile(page, 'z-add.txt');
  await file.scrollIntoViewIfNeeded();
  await file.getByRole('button', { name: 'new line 1', exact: true }).click();
  const form = page.locator('[data-inline-form]');
  await expect(form.locator('.CodeMirror-focused')).toBeVisible();
  await page.keyboard.insertText('Review on the second file page');
  await form.getByRole('button', { name: 'Start discussion', exact: true }).click();
  await expectFilePage(page, 2);
  const thread = page.locator('.mr-discussion').filter({ hasText: 'Review on the second file page' });
  await expect(thread).toBeVisible();
  const source = thread.locator('.discussion-anchor a');
  const sourceURL = new URL((await source.getAttribute('href'))!, mrURL);
  // Legacy source URLs lack a file page. Even an explicit stale page must be corrected.
  sourceURL.searchParams.set('page', '1');
  await page.goto(sourceURL.href);
  await expectFilePage(page, 2);
  await expect(diffFile(page, 'z-add.txt').getByRole('button', { name: 'new line 1', exact: true })).toBeInViewport();
  await page.reload();
  await expect(diffFile(page, 'z-add.txt').getByRole('button', { name: 'new line 1', exact: true })).toBeInViewport();
  const anchored = new URL(page.url());
  await page.getByRole('button', { name: 'AST', exact: true }).click();
  for (const key of ['version', 'commit', 'page', 'file_id', 'discussion', 'code']) {
    expect(new URL(page.url()).searchParams.get(key)).toBe(anchored.searchParams.get(key));
  }
  expect(new URL(page.url()).hash).toBe(anchored.hash);
  const anchoredAST = page.url();
  await page.getByRole('navigation', { name: 'Files', exact: true }).getByRole('link', { name: 'z-delete.txt', exact: true }).click();
  expect(new URL(page.url()).searchParams.has('code')).toBe(false);
  const otherFile = new URL(page.url()).searchParams.get('file_id');
  expect(otherFile).not.toBe(anchored.searchParams.get('file_id'));
  await page.getByRole('button', { name: 'Line', exact: true }).click();
  expect(new URL(page.url()).searchParams.get('file_id')).toBe(otherFile);
  await page.goto(anchoredAST);
  await expect(page.getByRole('button', { name: 'AST', exact: true })).toHaveAttribute('aria-pressed', 'true');
  await page.getByRole('link', { name: 'Previous files', exact: true }).click();
  await expectFilePage(page, 1);
  expect(new URL(page.url()).searchParams.has('code')).toBe(false);
  expect(new URL(page.url()).searchParams.has('file_id')).toBe(false);
  expect(new URL(page.url()).searchParams.get('discussion')).toBe(anchored.searchParams.get('discussion'));
  await expect(page.getByRole('button', { name: 'AST', exact: true })).toHaveAttribute('aria-pressed', 'true');
  const context = await browser.newContext({ javaScriptEnabled: false, storageState: await page.context().storageState() });
  const native = await context.newPage();
  await native.goto(sourceURL.href);
  await expectFilePage(native, 2);
  await expect(native.locator('[data-diff-fallback] .structured-diff')).toContainText('added source');
  await expect(native.locator('.mr-discussion')).toContainText('Review on the second file page');
  await native.getByRole('link', { name: 'ast', exact: true }).click();
  expect(new URL(native.url()).searchParams.get('code')).toBe(anchored.searchParams.get('code'));
  await expect(native.locator('[data-diff-fallback] .structured-diff')).toContainText('added source');
  await native.getByRole('link', { name: 'z-delete.txt', exact: true }).click();
  expect(new URL(native.url()).searchParams.has('code')).toBe(false);
  expect(new URL(native.url()).searchParams.get('file_id')).toBe(otherFile);
  await native.getByRole('link', { name: 'Previous files', exact: true }).click();
  await expectFilePage(native, 1);
  expect(new URL(native.url()).searchParams.has('code')).toBe(false);
  const notification = new URL(mrURL);
  notification.searchParams.set('discussion', sourceURL.searchParams.get('discussion')!);
  await native.goto(notification.href);
  await expectFilePage(native, 2);
  await expect(native.locator('[data-diff-fallback] .structured-diff')).toContainText('added source');
  await native.getByRole('link', { name: 'Previous files', exact: true }).click();
  await expectFilePage(native, 1);
  await expect(native.locator('[data-diff-fallback]')).toContainText('non-UTF-8 path');
  await context.close();
});

async function pagedPage(page: Page, kind: 'commit' | 'MR') {
  await login(page);
  if (kind === 'commit') {
    await page.goto('/alice/demo/commits?rev=moondiff-paged');
    await page.getByRole('row').filter({ hasText: 'Paged browser changes' }).getByRole('link').click();
  } else {
    await page.goto('/alice/demo/merge-requests');
    const existing = page.getByRole('link', { name: /^(Paged byte paths|Paged navigation state)$/, exact: true }).first();
    if (await existing.count()) {
      await existing.click();
      await page.getByRole('link', { name: 'Changes', exact: true }).click();
      await expect(page.getByRole('button', { name: 'Token', exact: true })).toHaveAttribute('aria-pressed', 'true');
      return;
    }
    await page.goto('/alice/demo/merge-requests/new');
    await page.getByLabel('Source branch', { exact: true }).selectOption('moondiff-paged');
    await page.getByLabel('Target branch', { exact: true }).selectOption('moondiff-paged-base');
    await page.getByLabel('Title', { exact: true }).fill('Paged navigation state');
    await page.getByRole('button', { name: 'Create merge request', exact: true }).click();
    await page.getByRole('link', { name: 'Changes', exact: true }).click();
  }
  await expect(page.getByRole('button', { name: 'Token', exact: true })).toHaveAttribute('aria-pressed', 'true');
}

async function expectFilePage(page: Page, number: number) {
  await expect(page).toHaveURL(url => url.searchParams.get('page') === String(number));
  await expect(page.locator('html')).not.toHaveAttribute('aria-busy');
  await expect.poll(async () => JSON.parse((await page.locator('moonhub-structured-diff').getAttribute('data-manifest'))!).page).toBe(number);
}

function expectQuery(url: string, values: Record<string, string>) {
  const query = new URL(url).searchParams;
  for (const [key, value] of Object.entries(values)) expect(query.getAll(key), key).toEqual([value]);
}

for (const kind of ['commit', 'MR'] as const) test(`${kind} pagination retains options, history and original draft coordinates`, async ({ page, context }) => {
  test.setTimeout(60000);
  await pagedPage(page, kind);
  const host = page.locator('moonhub-structured-diff');
  const manifest = JSON.parse((await host.getAttribute('data-manifest'))!);
  expect(manifest.files).toHaveLength(100);
  expect(manifest.has_more).toBe(true);
  const identity: Record<string, string> = kind === 'MR' ? { version: '1', commit: '' } : { fixed: '1' };
  await page.evaluate(() => history.replaceState({ ...history.state, retained: 'view state' }, '', location.href));
  const historyBefore = await page.evaluate(() => ({ state: history.state, length: history.length }));
  let pageRequests = 0;
  const fileRequests: string[] = [];
  page.on('request', request => {
    if (request.headers()['accept'] === 'application/vnd.moonhub.page+json') pageRequests++;
    if (new URL(request.url()).pathname.endsWith('/diff')) fileRequests.push(request.url());
  });
  await page.getByRole('button', { name: 'AST', exact: true }).click();
  await page.getByLabel('Ignore comments', { exact: true }).uncheck();
  // Line keeps the mixed filter preference through a reload.
  await page.getByRole('button', { name: 'Line', exact: true }).click();
  expectQuery(page.url(), { ...identity, page: '1', mode: 'line', ignore_comments: 'false', ignore_tests: 'true' });
  expect(await page.evaluate(() => ({ state: history.state, length: history.length }))).toEqual(historyBefore);
  expect(pageRequests).toBe(0);
  await page.reload();
  await page.getByRole('button', { name: 'AST', exact: true }).click();
  await expect(page.getByLabel('Ignore comments', { exact: true })).not.toBeChecked();
  await expect(page.getByLabel('Ignore tests', { exact: true })).toBeChecked();
  await page.getByLabel('Ignore tests', { exact: true }).uncheck();
  const options = { mode: 'ast', ignore_comments: 'false', ignore_tests: 'false' };
  const beforeAnchor = pageRequests;
  await page.getByRole('navigation', { name: 'Files', exact: true }).getByRole('link', { name: 'a-100.txt', exact: true }).click();
  await expect(page).toHaveURL(/#diff-file-/);
  expect(pageRequests).toBe(beforeAnchor);
  const chosen = manifest.files.find((file: { new_path: string }) => file.new_path === 'a-100.txt');
  expectQuery(page.url(), { ...options, file_id: chosen.id });
  await page.getByRole('button', { name: 'Token', exact: true }).click();
  await page.getByRole('button', { name: 'AST', exact: true }).click();
  expectQuery(page.url(), { ...options, file_id: chosen.id });
  // Ordinary in-page anchors still use the shell's synchronized currentURL.
  await page.getByRole('link', { name: 'Skip to content' }).focus();
  await page.getByRole('link', { name: 'Skip to content' }).press('Enter');
  await expect(page).toHaveURL(/#main-content$/);
  expect(pageRequests).toBe(beforeAnchor);
  const href = await page.getByRole('link', { name: 'Next files', exact: true }).getAttribute('href');
  expectQuery(href!, { ...identity, ...options, page: '2' });
  expect(new URL(href!).hash).toBe('');
  const copied = await context.newPage();
  await copied.goto(href!);
  await expect(copied.getByRole('button', { name: 'AST', exact: true })).toHaveAttribute('aria-pressed', 'true');
  await copied.close();
  fileRequests.length = 0;
  await page.getByRole('link', { name: 'Next files', exact: true }).click();
  await expectFilePage(page, 2);
  const file = diffFile(page, 'z-add.txt');
  await file.scrollIntoViewIfNeeded();
  await expect(file.getByRole('button', { name: 'new line 1', exact: true })).toBeVisible();
  expect(fileRequests.length).toBeGreaterThan(0);
  for (const url of fileRequests) expectQuery(url, options);
  expect(fileRequests.some(url => new URL(url).searchParams.get('page') === '2')).toBe(true);
  const form = page.locator('[data-inline-form]');
  let draft: Record<string, string> = {};
  if (kind === 'MR') {
    await file.getByRole('button', { name: 'new line 1', exact: true }).click();
    await page.keyboard.insertText('Keep the original paged comparison');
    draft = await form.evaluate(node => Object.fromEntries([...new FormData(node as HTMLFormElement)].filter(([key]) =>
      ['body', 'document_id', 'file_id', 'hunk_id', 'diff_page', 'mode', 'ignore_comments', 'ignore_tests', 'side', 'start_line', 'end_line'].includes(key))) as Record<string, string>);
    await page.getByRole('button', { name: 'Line', exact: true }).click();
  }
  await page.getByRole('link', { name: 'Previous files', exact: true }).click();
  await expectFilePage(page, 1);
  await page.goBack();
  await expectFilePage(page, 2);
  const retained = { ...options, mode: kind === 'MR' ? 'line' : 'ast' };
  expectQuery(page.url(), { ...identity, ...retained, page: '2' });
  await expect(page.getByRole('button', { name: kind === 'MR' ? 'Line' : 'AST', exact: true })).toHaveAttribute('aria-pressed', 'true');
  await page.goForward();
  await expectFilePage(page, 1);
  await page.goBack();
  await expectFilePage(page, 2);
  await page.reload();
  expectQuery(page.url(), { ...identity, ...retained, page: '2' });
  if (kind === 'MR') {
    for (const [name, value] of Object.entries(draft)) await expect(form.locator(`[name=${name}]`)).toHaveValue(value);
    await page.locator('#inline-composer > summary').click();
    await form.getByRole('button', { name: 'Start discussion', exact: true }).click();
    await expect(page.locator('.mr-discussion').filter({ hasText: 'Keep the original paged comparison' })).toBeVisible();
  }
});

for (const kind of ['commit', 'MR'] as const) test(`${kind} native mode and filter links retain the second-page file without duplicate parameters`, async ({ page, browser }) => {
  await pagedPage(page, kind);
  const url = new URL(page.url());
  url.searchParams.set('page', '2');
  if (kind === 'MR') {
    const manifest = JSON.parse((await page.locator('moonhub-structured-diff').getAttribute('data-manifest'))!);
    url.searchParams.set('version', '1'); url.searchParams.set('commit', manifest.head_sha);
    url.searchParams.set('discussion_page', '3'); url.searchParams.set('commit_page', '2'); url.searchParams.set('filter', 'unresolved');
  }
  const context = await browser.newContext({ javaScriptEnabled: false, storageState: await page.context().storageState() });
  const native = await context.newPage();
  await native.goto(url.href);
  await native.getByRole('link', { name: 'z-add.txt', exact: true }).click();
  const selected = new URL(native.url());
  const position = Object.fromEntries([...selected.searchParams].filter(([key]) => !['mode', 'ignore_comments', 'ignore_tests'].includes(key)));
  expect(position.file_id).toHaveLength(64);
  for (const mode of ['ast', 'line', 'lexical']) {
    await native.getByRole('link', { name: mode, exact: true }).click();
    expectQuery(native.url(), { ...position, mode, ignore_comments: 'true', ignore_tests: 'true' });
    await expect(native.locator('[data-diff-fallback] .structured-diff')).toContainText('added source');
  }
  await native.getByRole('link', { name: 'Ignore comments: true', exact: true }).click();
  await native.getByRole('link', { name: 'Ignore tests: true', exact: true }).click();
  expectQuery(native.url(), { ...position, mode: 'lexical', ignore_comments: 'false', ignore_tests: 'false' });
  expect(new URL(native.url()).hash).toBe('#diff-code');
  await native.getByRole('link', { name: 'Previous files', exact: true }).click();
  expectQuery(native.url(), { page: '1', mode: 'lexical', ignore_comments: 'false', ignore_tests: 'false' });
  expect(new URL(native.url()).searchParams.has('file_id')).toBe(false);
  expect(new URL(native.url()).hash).toBe('');
  await context.close();
});

for (const action of ['click', 'history'] as const) test(`view URL updates reject invalid sources and pending ${action} navigation without changing diff state`, async ({ page }) => {
  await login(page);
  await commitPage(page);
  const original = page.url();
  expect(await page.evaluate(() => {
    const host = document.querySelector('moonhub-structured-diff')!;
    return [[document, location.href], [host, 'https://example.com/'], [host, '/-/login']].map(([source, url]) =>
      (source as EventTarget).dispatchEvent(new CustomEvent('moonhub:replace-view-url', { bubbles: true, cancelable: true, detail: { url } })));
  })).toEqual([false, false, false]);
  expect(page.url()).toBe(original);
  let release!: () => void, started!: () => void;
  const gate = new Promise<void>(resolve => { release = resolve; });
  const intercepted = new Promise<void>(resolve => { started = resolve; });
  await page.route(action === 'click' ? '**/alice/demo' : '**/commits?rev=moondiff-feature', async route => {
    const response = await route.fetch(); started(); await gate;
    await route.fulfill({ response });
  });
  if (action === 'click') await page.getByRole('link', { name: 'Files', exact: true }).first().click();
  else await page.goBack();
  await intercepted;
  const pendingURL = page.url();
  await page.getByRole('button', { name: 'AST', exact: true }).click();
  await page.getByLabel('Ignore comments', { exact: true }).click();
  expect(page.url()).toBe(pendingURL);
  await expect(page.getByRole('button', { name: 'Token', exact: true })).toHaveAttribute('aria-pressed', 'true');
  await expect(page.getByLabel('Ignore comments', { exact: true })).toBeChecked();
  release();
  await expect(page.locator('moonhub-structured-diff')).toHaveCount(0);
  if (action === 'click') await page.goBack();
  else await page.goForward();
  await expect(page.getByRole('button', { name: 'Token', exact: true })).toHaveAttribute('aria-pressed', 'true');
});

test('view URL updates are rejected during submissions, page replacement and vetoed history restoration', async ({ page }) => {
  await login(page);
  await commitPage(page);
  const original = page.url();
  let release!: () => void, started!: () => void;
  const gate = new Promise<void>(resolve => { release = resolve; });
  const intercepted = new Promise<void>(resolve => { started = resolve; });
  await page.route(original, async route => {
    // Serve the current page without making a server-side mutation.
    const response = await route.fetch({ method: 'GET' }); started(); await gate;
    await route.fulfill({ response });
  });
  await page.evaluate(() => {
    const form = document.createElement('form'); form.method = 'post'; form.action = location.href;
    document.querySelector('main')!.append(form); form.requestSubmit();
    document.addEventListener('moonhub:rendered', () => {
      const url = new URL(location.href); url.searchParams.set('mode', 'ast');
      const accepted = document.querySelector('moonhub-structured-diff')!.dispatchEvent(new CustomEvent('moonhub:replace-view-url', {
        bubbles: true, cancelable: true, detail: { url: url.href },
      }));
      document.documentElement.dataset.replacementAccepted = String(accepted);
    }, { once: true });
  });
  await intercepted;
  await page.getByRole('button', { name: 'AST', exact: true }).click();
  expect(page.url()).toBe(original);
  await expect(page.getByRole('button', { name: 'Token', exact: true })).toHaveAttribute('aria-pressed', 'true');
  release();
  await expect(page.locator('html')).toHaveAttribute('data-replacement-accepted', 'false');
  await expect(page.locator('html')).not.toHaveAttribute('aria-busy');
  await page.unroute(original);
  await page.evaluate(() => {
    document.addEventListener('moonhub:before-navigate', event => event.preventDefault(), { once: true });
    window.addEventListener('popstate', () => {
      const url = new URL(location.href); url.searchParams.set('mode', 'ast');
      const accepted = document.querySelector('moonhub-structured-diff')!.dispatchEvent(new CustomEvent('moonhub:replace-view-url', {
        bubbles: true, cancelable: true, detail: { url: url.href },
      }));
      document.documentElement.dataset.restorationAccepted = String(accepted);
    }, { once: true });
  });
  // The POST created an entry with the same URL. Step over it to request the
  // commits list, then veto and restore the mounted commit's history entry.
  await page.evaluate(() => history.go(-2));
  await expect(page.locator('html')).toHaveAttribute('data-restoration-accepted', 'false');
  await expect(page).toHaveURL(original);
  await expect(page.getByRole('button', { name: 'Token', exact: true })).toHaveAttribute('aria-pressed', 'true');
});
