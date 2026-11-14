import { test, expect, type Page } from '@playwright/test';

async function login(page: Page) {
  await page.goto('/-/login');
  await expect(page.locator('html')).toHaveAttribute('data-hydrated', 'true');
  await page.locator('[name=name_key]').fill('alice');
  await page.locator('[name=password]').fill('browser-test-password');
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  await expect(page).toHaveURL(/\/$/, { timeout: 15000 });
}

async function fillMarkdown(page: Page, selector: string, value: string) {
  const textarea = page.locator(selector);
  await textarea.evaluate(element => element.dispatchEvent(new Event('markdown-focus', { cancelable: true })));
  await expect(textarea).toHaveAttribute('data-markdown-source', 'easymde');
  await textarea.evaluate((element, value) => (element.closest('.markdown-editor')!.querySelector('.CodeMirror') as any).CodeMirror.setValue(value), value);
}

for (const width of [320, 390, 900, 1440]) {
  test(`repository navigation, menus and file finder at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 1000 });
    await login(page);
    for (const [path, active] of [
      ['', 'Code'], ['/issues?assigned=me', 'Issues'], ['/merge-requests?mine=author', 'Pull requests'],
      ['/pipelines?tab=events', 'Actions'], ['/releases', 'Code'], ['/settings/variables', 'Settings'],
    ]) {
      await page.goto('/alice/demo' + path);
      await expect(page.locator('.repository-tabs a[aria-current]')).toHaveText(active);
      await expect(page.locator('.repository-tabs a')).toHaveText(['Code', 'Issues', 'Pull requests', 'Actions', 'Settings']);
      await expect(page.locator('#app-sidebar')).toHaveCount(path ? 1 : 0);
      expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    }
    await page.goto('/alice/demo');
    await expect(page.locator('.readme-preview')).toContainText('README.md');
    await page.keyboard.press('t');
    await expect(page.locator('[data-file-query]')).toBeFocused();
    await page.locator('[data-file-query]').fill('README');
    await expect(page.locator('[data-file-result]:visible')).toHaveCount(1);
    await page.keyboard.press('t');
    await expect(page.locator('[data-file-query]')).toHaveValue('READMEt');
    await page.keyboard.press('Escape');
    await expect(page.locator('[data-file-finder]')).not.toHaveAttribute('open', '');
    await expect(page.locator('[data-file-finder] > summary')).toBeFocused();
    await expect(page.locator('#app-sidebar, [data-sidebar-open], [data-sidebar-collapse]')).toHaveCount(0);
    await page.locator('.global-navigation > summary').click();
    await expect(page.locator('.global-navigation nav')).toBeVisible();
    await expect(page.locator('.global-navigation nav .nav-label').first()).toBeVisible();
    await page.keyboard.press('Escape');
    await expect(page.locator('.global-navigation > summary')).toBeFocused();
    await page.locator('.repository-tabs').getByRole('link', { name: 'Issues', exact: true }).click();
    await expect(page.locator('#app-sidebar')).toHaveCount(1);
    if (width <= 900) {
      await page.getByRole('button', { name: 'Open navigation', exact: true }).click();
      await expect(page.locator('#app-sidebar')).toHaveAttribute('aria-modal', 'true');
      await page.keyboard.press('Escape');
      await expect(page.getByRole('button', { name: 'Open navigation', exact: true })).toBeFocused();
    }
  });
}

test('title search shortcut and URL filters survive history navigation', async ({ page }) => {
  await login(page);
  await page.goto('/alice/demo/issues?status=closed&assigned=me&q=missing');
  await page.keyboard.press('/');
  await expect(page.locator('[name=q]')).toBeFocused();
  await page.keyboard.press('t');
  await expect(page.locator('[name=q]')).toHaveValue('t');
  await page.getByRole('button', { name: 'Filter', exact: true }).click();
  await expect(page).toHaveURL(/status=closed.*q=t.*assigned=me/);
  await expect(page.locator('html')).not.toHaveAttribute('aria-busy', 'true');
  await page.locator('.repository-tabs').getByRole('link', { name: 'Code', exact: true }).click();
  await expect(page).toHaveURL(/alice\/demo$/);
  await expect(page.locator('html')).not.toHaveAttribute('aria-busy', 'true');
  await page.goBack();
  await expect(page.locator('[name=q]')).toHaveValue('t');
  await expect(page.locator('[name=assigned]')).toHaveValue('me');
});

test('Markdown preview and code preserve exact clipboard contents and line links', async ({ page }) => {
  await login(page);
  await page.context().grantPermissions(['clipboard-read', 'clipboard-write']);
  await page.goto('/alice/demo/blob/master/README.md');
  await expect(page.locator('[data-file-preview]')).toBeVisible();
  await expect(page.locator('[data-file-code]')).toBeHidden();
  const source = await page.locator('[data-file-source]').textContent();
  await page.getByRole('button', { name: 'Copy text', exact: true }).click();
  expect(await page.evaluate(() => navigator.clipboard.readText())).toBe(source);
  await page.getByRole('button', { name: 'Copy path', exact: true }).click();
  expect(await page.evaluate(() => navigator.clipboard.readText())).toBe('README.md');
  await page.getByRole('button', { name: 'Code', exact: true }).click();
  await expect(page.locator('[data-file-code]')).toBeVisible();
  await expect(page.locator('.moonhub-file-view')).toBeVisible();
  await page.goto('/alice/demo/blob/master/README.md#L1');
  await expect(page.locator('[data-file-code]')).toBeVisible();
  await expect(page.locator('[data-file-preview]')).toBeHidden();
});

test('pull request creation and review use existing fields, versions and independent references', async ({ page }) => {
  await login(page);
  await page.goto('/alice/demo/merge-requests/new');
  expect(await page.locator('.mr-branch-fields select').evaluateAll(fields => fields.map(field => field.getAttribute('name')))).toEqual(['target', 'source']);
  await page.getByLabel('Base branch', { exact: true }).selectOption('moondiff-base');
  await page.getByLabel('Compare branch', { exact: true }).selectOption('moondiff-feature');
  await page.getByLabel('Title', { exact: true }).fill('Repository UX review');
  await fillMarkdown(page, 'textarea[name=description]', 'Review !1 and #1 independently.');
  await page.getByRole('combobox', { name: 'Creation mode', exact: true }).selectOption('on');
  await page.getByRole('button', { name: 'Create pull request', exact: true }).click();
  await expect(page).toHaveURL(/merge-requests\/\d+$/);
  await expect(page.locator('.mr-state').first()).toHaveText('Draft');
  await expect(page.locator('.mr-tabs a')).toHaveText(['Conversation', 'Commits', 'Files changed']);
  await expect(page.locator('.mr-main [aria-label="Merge status"]')).toBeVisible();
  await expect(page.locator('.mr-sidebar .mr-reviewers')).toBeVisible();
  await page.getByText('Write a comment or review', { exact: true }).click();
  await fillMarkdown(page, '.mr-review-form textarea[name=body]', 'Draft review survives tab navigation');
  await page.getByRole('link', { name: 'Files changed', exact: true }).click();
  await page.getByText('Review changes', { exact: true }).click();
  await expect(page.locator('.mr-review-form textarea[name=body]')).toHaveValue('Draft review survives tab navigation');
  await expect(page.locator('.mr-main [aria-label="Merge status"]')).toHaveCount(0);
  await expect(page.locator('.structured-toolbar')).toHaveCount(1);
  await expect(page.getByRole('button', { name: 'Token', exact: true })).toHaveAttribute('aria-pressed', 'true');
  await page.locator('.mr-more-actions > summary').click();
  await page.getByRole('button', { name: 'Close', exact: true }).click();
  await expect(page.locator('.mr-page-heading .mr-state')).toHaveText('Closed');
});

test('release cards render safe Markdown and keep native asset lists collapsible', async ({ page }) => {
  await login(page);
  await page.goto('/alice/demo/releases/new');
  const tag = `ux-${Date.now()}`;
  await page.getByLabel('Version tag', { exact: true }).fill(tag);
  await page.getByLabel('Title', { exact: true }).fill('UX release');
  await page.getByLabel('Release notes', { exact: true }).fill('## Changes\n\n**Ready**\n\n<script>window.releaseExecuted=true</script>');
  await page.getByRole('button', { name: 'Create draft', exact: true }).click();
  await expect(page).toHaveURL(/releases\/\d+$/);
  await expect(page.locator('.release-notes strong')).toHaveText('Ready');
  expect(await page.evaluate(() => (window as any).releaseExecuted)).toBeUndefined();
  await page.locator('.release-assets > summary').click();
  await expect(page.locator('.release-assets ul')).toBeHidden();
  await page.getByRole('button', { name: 'Publish release', exact: true }).click();
  await expect(page.locator('.status-badge')).toHaveText('Published');
  await page.locator('main').getByRole('link', { name: 'Releases', exact: true }).click();
  await expect(page.locator('.release-row').filter({ hasText: tag }).locator('strong')).toHaveText('Ready');
  await page.locator('.repository-tabs').getByRole('link', { name: 'Code', exact: true }).click();
  const summary = page.locator('.repository-releases');
  await expect(summary.getByRole('link', { name: 'UX release', exact: true })).toBeVisible();
  await expect(summary).toContainText(tag);
  await expect(summary.locator('.latest-release')).toHaveText('Latest');
  await expect(summary.locator('time')).toHaveAttribute('datetime', /T.*Z$/);
  await summary.getByRole('link', { name: 'UX release', exact: true }).click();
  await expect(page.locator('.repository-releases')).toHaveCount(0);
});

test('repository code controls and native line anchors work without JavaScript', async ({ page, browser }) => {
  await login(page);
  const context = await browser.newContext({ javaScriptEnabled: false, storageState: await page.context().storageState() });
  const native = await context.newPage();
  await native.goto(new URL('/alice/demo', page.url()).href);
  await expect(native.locator('#app-sidebar, [data-sidebar-open], [data-sidebar-collapse]')).toHaveCount(0);
  for (const width of [320, 390, 900, 1440]) {
    await native.setViewportSize({ width, height: 1000 });
    await expect(native.locator('.repository-releases')).toBeVisible();
    expect(await native.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    if (width <= 900) {
      const rail = (await native.locator('.repository-releases').boundingBox())!;
      const readme = (await native.locator('.readme-preview').boundingBox())!;
      expect(rail.y).toBeGreaterThan(readme.y + readme.height);
    }
  }
  await native.locator('.commit-history').click();
  await expect(native.locator('main')).toContainText('Commits');
  await native.goBack();
  await native.locator('[data-file-finder] > summary').click();
  await native.locator('[data-file-result]').getByRole('link', { name: 'README.md', exact: true }).click();
  await expect(native.locator('[data-file-preview]')).toBeVisible();
  await native.getByRole('link', { name: 'Line 1', exact: true }).click();
  await expect(native).toHaveURL(/#L1$/);
  await native.locator('.global-navigation > summary').click();
  await expect(native.locator('.global-navigation nav')).toBeVisible();
  await native.locator('.global-navigation > summary').click();
  await expect(native.locator('.global-navigation nav')).toBeHidden();
  await context.close();
});

for (const width of [320, 390, 900, 1440]) {
  test(`Code commit links and root release summary at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 1000 });
    await login(page);
    await page.goto('/alice/demo');
    await expect(page.locator('[data-sidebar-open], #app-sidebar')).toHaveCount(0);
    await expect(page.locator('.code-toolbar').getByRole('link', { name: 'History', exact: true })).toHaveCount(0);
    const summary = page.locator('.commit-summary');
    const history = summary.getByRole('link', { name: '1 commit', exact: true });
    await expect(history).toHaveAttribute('href', '/alice/demo/commits?rev=master');
    const links = await summary.locator('a').evaluateAll(links => links.map(a => a.getAttribute('href')));
    expect(links[0]).toBe(links[1]);
    expect(links[0]).toMatch(/\/commit\/[a-f0-9]{40}$/);
    const summaryBounds = (await summary.boundingBox())!, historyBounds = (await history.boundingBox())!;
    expect(historyBounds.x + historyBounds.width).toBeCloseTo(summaryBounds.x + summaryBounds.width - 17, 0);
    expect(historyBounds.y).toBeLessThan((await page.locator('.file-table').boundingBox())!.y);
    const release = page.locator('.repository-releases');
    await expect(release.getByRole('link', { name: 'View all releases' })).toHaveAttribute('href', '/alice/demo/releases');
    const rail = (await release.boundingBox())!, main = (await page.locator('.repository-files').boundingBox())!;
    if (width > 900) {
      expect(rail.width).toBe(296);
      expect(rail.x - main.x - main.width).toBe(32);
    } else {
      expect(rail.y).toBeGreaterThan((await page.locator('.readme-preview').boundingBox())!.y + (await page.locator('.readme-preview').boundingBox())!.height);
    }
    await history.click();
    await expect(page).toHaveURL(/commits\?rev=master$/);
    await expect(page.locator('.repository-releases, #app-sidebar')).toHaveCount(0);
    await page.goBack();
    // The branch has a slash and a same-named tag pointing at a different commit.
    for (const label of ['Branch: feature/context', 'Tag: feature/context']) {
      await page.locator('.branch-picker > summary').click();
      const choice = page.locator('.branch-picker-panel').getByRole('link', { name: label, exact: true });
      const chosen = new URL((await choice.getAttribute('href'))!, page.url()).searchParams.get('rev')!;
      await choice.click();
      await expect(page.locator('.commit-history')).toHaveAttribute('href', '/alice/demo/commits?rev=' + chosen);
      await expect(page.locator('.commit-history')).toHaveText(label.startsWith('Branch:') ? '2 commits' : '1 commit');
      await expect(page.locator('.commit-subject')).toHaveAttribute('href', '/alice/demo/commit/' + chosen);
      await expect(release).toHaveCount(1);
      await page.locator('.commit-history').click();
      await expect(page).toHaveURL(new RegExp('commits\\?rev=' + chosen + '$'));
      await page.goBack();
    }
    await page.goto('/alice/demo/tree/master/src');
    await expect(release).toHaveCount(0);
    await expect(page.locator('.commit-history')).toHaveAttribute('href', '/alice/demo/commits?rev=master');
    await page.goto('/alice/demo/blob/master/README.md');
    await expect(page.locator('.directory-navigation')).toBeVisible();
    await expect(page.getByRole('link', { name: 'History', exact: true })).toBeVisible();
    await expect(release).toHaveCount(0);
    await page.goto('/alice/empty');
    await expect(page.locator('.commit-summary')).toContainText('No commits yet.');
    await expect(page.locator('.commit-history')).toHaveText('0 commits');
    await expect(page.locator('a[href*="/empty/commit/"]')).toHaveCount(0);
    await page.locator('.commit-history').click();
    await expect(page.locator('main')).toContainText('No commits.');
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
  });
}

test('Code and feature sidebars preserve SPA history, collapse preference and drawer focus', async ({ page }) => {
  await login(page);
  await page.goto('/alice/demo/issues');
  await page.getByRole('button', { name: 'Collapse sidebar', exact: true }).click();
  await page.evaluate(() => { (window as any).uxDocument = document; });
  await page.locator('.repository-tabs').getByRole('link', { name: 'Code', exact: true }).click();
  await expect(page.locator('#app-sidebar')).toHaveCount(0);
  await expect(page.locator('html')).toHaveAttribute('data-ui-ready', 'true');
  await expect(page.locator('html')).not.toHaveAttribute('data-sidebar-collapsed');
  expect(await page.evaluate(() => localStorage.getItem('moonhub.sidebar'))).toBe('collapsed');
  await expect(page.locator('main')).toBeFocused();
  await page.locator('.global-navigation > summary').click();
  await expect(page.locator('main')).toHaveAttribute('inert', '');
  await page.keyboard.press('Shift+Tab');
  await expect(page.locator('.global-navigation > summary')).toBeFocused();
  await page.keyboard.press('Shift+Tab');
  await expect(page.locator('.global-navigation nav a').last()).toBeFocused();
  await page.keyboard.press('Escape');
  await expect(page.locator('main')).not.toHaveAttribute('inert');
  await expect(page.locator('.global-navigation > summary')).toBeFocused();
  await page.keyboard.press('/');
  await expect(page.locator('.global-navigation > summary')).toBeFocused();
  await page.keyboard.press('t');
  await expect(page.locator('[data-file-query]')).toBeFocused();
  await page.keyboard.press('Escape');
  await page.goBack();
  await expect(page.getByRole('button', { name: 'Expand sidebar', exact: true })).toBeVisible();
  await page.goForward();
  await expect(page.locator('#app-sidebar')).toHaveCount(0);
  await page.locator('.repository-tabs').getByRole('link', { name: 'Issues', exact: true }).click();
  await expect(page.getByRole('button', { name: 'Expand sidebar', exact: true })).toBeVisible();
  expect(await page.evaluate(() => (window as any).uxDocument === document)).toBe(true);
});
