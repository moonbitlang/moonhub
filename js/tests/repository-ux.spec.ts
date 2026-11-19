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

test('Clone menu stays inside the viewport and copies the full SSH URL', async ({ page }) => {
  await login(page);
  await page.context().grantPermissions(['clipboard-read', 'clipboard-write']);
  const trigger = page.locator('.repo-clone > summary');
  const panel = page.locator('.repo-clone-panel');
  const url = 'ssh://git@ssh.example.test:2222/alice/demo.git';
  for (const path of ['/alice/demo/commits', '/alice/demo']) {
    await page.goto(path);
    await expect(page.locator('html')).toHaveAttribute('data-hydrated', 'true');
    for (const width of [1280, 1440, 320]) {
      const height = 900;
      await page.setViewportSize({ width, height });
      await trigger.click();
      const box = (await panel.boundingBox())!;
      expect(box.x).toBeGreaterThanOrEqual(20);
      expect(box.x + box.width).toBeLessThanOrEqual(width - 20);
      expect(box.width).toBeCloseTo(Math.min(440, width - 40), 0);
      expect(box.y).toBeGreaterThanOrEqual(0);
      expect(box.y + box.height).toBeLessThanOrEqual(height);
      expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
      await expect(panel.getByLabel('Clone with SSH')).toHaveValue(url);
      await panel.getByRole('button', { name: 'Copy SSH URL' }).click();
      await expect(panel.getByRole('status')).toHaveText('SSH URL copied.');
      expect(await page.evaluate(() => navigator.clipboard.readText())).toBe(url);
      await page.keyboard.press('Escape');
      await expect(panel).toBeHidden();
      await expect(trigger).toBeFocused();
    }
  }
  await page.setViewportSize({ width: 1280, height: 900 });
  const triggerBox = (await trigger.boundingBox())!;
  await page.setViewportSize({ width: 1280, height: Math.ceil(triggerBox.y + triggerBox.height) + 25 });
  await trigger.click();
  const flipped = (await panel.boundingBox())!;
  expect(flipped.y).toBeGreaterThanOrEqual(0);
  expect(flipped.y + flipped.height).toBeLessThan((await trigger.boundingBox())!.y);
});

test('notification settings keep unsaved changes until the form is submitted', async ({ page }) => {
  await login(page);
  await page.goto('/-/notifications');
  await page.getByRole('link', { name: 'Notification settings', exact: true }).click();
  await expect(page).toHaveURL('/-/notifications?settings=1');
  const header = page.locator('.page-heading');
  const settings = header.getByText('Notification settings', { exact: true });
  await expect(header.getByRole('link', { name: 'Notification settings' })).toHaveCount(0);
  await expect(settings).toHaveAttribute('aria-current', 'page');
  const email = page.getByRole('checkbox', { name: 'Email me about collaboration updates' });
  const checked = !(await email.isChecked());
  await email.setChecked(checked);
  await settings.click();
  await expect(email).toBeChecked({ checked });
  await page.getByRole('button', { name: 'Save notification settings' }).click();
  await expect(page.getByText('Notification settings saved.')).toBeVisible();
  await page.reload();
  await expect(email).toBeChecked({ checked });
});

test('branch protection breadcrumb links back to the repository', async ({ page }) => {
  await login(page);
  await page.goto('/alice/demo/settings/branches');
  await expect(page.getByRole('heading', { name: 'Branch protection', exact: true })).toBeVisible();
  await expect(page.locator('.repository-tabs a[aria-current]')).toHaveText('Settings');
  const trail = page.getByRole('navigation', { name: 'Breadcrumb', exact: true });
  await expect(trail.getByRole('listitem')).toHaveText(['demo', 'Settings', 'Branch protection']);
  await expect(trail.locator('span[aria-current=page]')).toHaveText('Branch protection');
  await expect(trail.getByRole('link')).toHaveCount(1);
  await trail.getByRole('link', { name: 'demo', exact: true }).click();
  await expect(page).toHaveURL('/alice/demo');
  await expect(page.locator('.file-table')).toBeVisible();
});

test('issue details show a description card only for nonblank descriptions', async ({ page }) => {
  await login(page);
  for (const [title, description] of [
    ['Title only', ''], ['Whitespace description', ' \n\t '], ['With description', '**Rendered body**'],
  ]) {
    await page.goto('/alice/demo/issues/new');
    await expect(page.locator('html')).toHaveAttribute('data-hydrated', 'true');
    await page.getByLabel('Title', { exact: true }).fill(title);
    if (description) await fillMarkdown(page, 'textarea[name=description]', description);
    await page.getByRole('button', { name: 'Create issue', exact: true }).click();
    await expect(page).toHaveURL(/\/issues\/\d+$/);
    await expect(page.getByRole('heading', { name: new RegExp(title) })).toBeVisible();
    await expect(page.getByText('Opened by Alice', { exact: false })).toBeVisible();
    const activity = page.locator('.mr-timeline .mr-event-heading');
    await expect(activity).toContainText('opened');
    await expect(activity.locator('time')).toHaveAttribute('datetime', /T.*Z$/);
    const card = page.locator('.discussion-description');
    if (description.trim()) {
      await expect(card.locator('strong')).toHaveText('Rendered body');
    } else {
      await expect(card).toHaveCount(0);
    }
  }
});

test('repository creation forms share the release form width at desktop and narrow sizes', async ({ page }) => {
  await login(page);
  for (const section of ['issues', 'merge-requests', 'releases']) {
    await page.goto('/alice/demo/' + section + '/new');
    const form = page.locator('main form.repository-form');
    const fields = section === 'releases'
      ? ['input[name=title]', 'textarea[name=body]']
      : ['input[name=title]', '.markdown-editor', '.markdown-editor-toolbar'];
    for (const [width, max] of [[1440, 720], [1600, 760], [320, 720]]) {
      await page.setViewportSize({ width, height: 900 });
      const available = await page.locator('main').evaluate(element => {
        const style = getComputedStyle(element);
        return element.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight);
      });
      const expected = Math.min(available, max);
      await expect(form).toBeVisible();
      expect((await form.boundingBox())!.width).toBeCloseTo(expected, 0);
      for (const field of fields) {
        await expect(form.locator(field)).toBeVisible();
        expect((await form.locator(field).boundingBox())!.width).toBeCloseTo(expected, 0);
      }
      expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    }
  }
});

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
    const panel = (await page.locator('.file-finder-panel').boundingBox())!;
    expect(panel.x).toBeGreaterThanOrEqual(20);
    expect(panel.x + panel.width).toBeLessThanOrEqual(width - 20);
    expect(panel.y).toBeGreaterThanOrEqual(0);
    expect(panel.y + panel.height).toBeLessThanOrEqual(1000);
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

test('latest commit Actions status opens its workflow list and links to run details', async ({ page }) => {
  await login(page);
  await page.goto('/alice/demo');
  await expect(page.locator('html')).toHaveAttribute('data-hydrated', 'true');
  const subject = page.locator('.commit-subject');
  const trigger = page.locator('.commit-actions > summary');
  const panel = page.locator('.commit-actions-panel');
  await expect(trigger).toHaveAccessibleName('Actions · Failed · 1 of 2 passed');
  for (const width of [320, 601, 1280]) {
    await page.setViewportSize({ width, height: 900 });
    const messageBounds = (await subject.boundingBox())!;
    const triggerBounds = (await trigger.boundingBox())!;
    const gap = triggerBounds.x - (messageBounds.x + messageBounds.width);
    expect(gap).toBeGreaterThanOrEqual(0);
    expect(gap).toBeLessThanOrEqual(8);
    expect(Math.abs(triggerBounds.y + triggerBounds.height / 2 - (messageBounds.y + messageBounds.height / 2))).toBeLessThan(1);
    await trigger.focus();
    await page.keyboard.press('Enter');
    await expect(panel).toBeVisible();
    await expect(panel.getByRole('link', { name: 'Build and package Passed' })).toBeVisible();
    const bounds = (await panel.boundingBox())!;
    expect(bounds.x).toBeGreaterThanOrEqual(0);
    expect(bounds.x + bounds.width).toBeLessThanOrEqual(width);
    const triggerCenter = triggerBounds.x + triggerBounds.width / 2;
    expect(triggerCenter).toBeGreaterThanOrEqual(bounds.x);
    expect(triggerCenter).toBeLessThanOrEqual(bounds.x + bounds.width);
    await page.keyboard.press('Escape');
    await expect(panel).toBeHidden();
    await expect(trigger).toBeFocused();
  }
  await trigger.click();
  await page.locator('h1').click();
  await expect(panel).toBeHidden();
  await trigger.click();
  await panel.getByRole('link', { name: 'Lint Failed' }).click();
  await expect(page).toHaveURL(/\/alice\/demo\/pipelines\/2$/);
  await expect(page.getByRole('heading', { name: 'Lint', exact: true })).toBeVisible();
});

test('file finder follows its trigger through resizing and scrolling with a long file list', async ({ page }) => {
  await login(page);
  await page.goto('/alice/demo?rev=moondiff-paged-base');
  await page.keyboard.press('t');
  const finder = page.locator('[data-file-finder]');
  const panel = finder.locator('.file-finder-panel');
  const query = finder.locator('[data-file-query]');
  await expect(query).toBeFocused();
  await expect(finder.locator('[data-file-result]')).toHaveCount(107);
  for (const [width, height] of [[2560, 1000], [1440, 700], [900, 700], [390, 700], [320, 360], [390, 360]]) {
    await page.setViewportSize({ width, height });
    const trigger = (await finder.locator('summary').boundingBox())!;
    const bounds = (await panel.boundingBox())!;
    expect(bounds.x).toBeGreaterThanOrEqual(20);
    expect(bounds.x + bounds.width).toBeLessThanOrEqual(width - 20);
    expect(bounds.y).toBeGreaterThanOrEqual(6);
    expect(bounds.y + bounds.height).toBeLessThanOrEqual(height - 6);
    expect(bounds.y >= trigger.y + trigger.height || bounds.y + bounds.height <= trigger.y).toBe(true);
    await query.click();
    await expect(finder.locator('[data-file-result]').first()).toBeInViewport();
    expect(await panel.evaluate(element => element.scrollHeight > element.clientHeight)).toBe(true);
    await panel.evaluate(element => { element.scrollTop = element.scrollHeight; });
    await expect(finder.locator('[data-file-result]').last()).toBeInViewport();
    await panel.evaluate(element => { element.scrollTop = 0; });
  }
  await page.setViewportSize({ width: 1440, height: 700 });
  const before = (await panel.boundingBox())!;
  await page.evaluate(() => window.scrollBy(0, 30));
  await expect.poll(async () => Math.round((await panel.boundingBox())!.y)).toBe(Math.round(before.y - 30));
  await page.locator('h1').click();
  await expect(finder).not.toHaveAttribute('open', '');
});

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

async function expectSourceLines(page: Page, start: number, end = start) {
  await expect(page.locator('[data-file-code]')).toBeVisible();
  await expect(page.locator('[data-file-preview]')).toBeHidden();
  await expect(page.getByRole('button', { name: 'Code', exact: true })).toHaveAttribute('aria-pressed', 'true');
  const lines = page.locator('moonhub-file-view [data-line][data-selected-line]');
  await expect.poll(() => lines.evaluateAll(nodes => nodes.map(node => Number(node.getAttribute('data-line')))))
    .toEqual(Array.from({ length: end - start + 1 }, (_, i) => start + i));
  await expect(lines.first()).toBeInViewport();
  await expect(lines.last()).toBeInViewport();
}

for (const width of [390, 1440]) {
  test(`Preview source links reveal, select and scroll code without requests at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 900 });
    await login(page);
    await page.goto('/alice/demo/blob/preview-line-links/line-links.md');
    await expect(page.locator('html')).toHaveAttribute('data-hydrated', 'true');
    await expect(page.locator('.moonhub-file-view')).toBeAttached();
    const url = page.url();
    const requests: string[] = [];
    page.on('request', request => {
      if (request.isNavigationRequest() || request.headers()['accept'] === 'application/vnd.moonhub.page+json') requests.push(request.url());
    });
    await page.evaluate(() => {
      (window as any).uxDocument = document;
      (window as any).uxHashChanges = [];
      window.addEventListener('hashchange', event => (window as any).uxHashChanges.push([event.oldURL, event.newURL]));
    });
    const changes: string[][] = [];
    for (const [label, hash, start, end] of [
      ['Near source', '#L2', 2, 2],
      ['Distant source', '#L180', 180, 180],
      ['Source range', '#L180-L183', 180, 183],
    ] as const) {
      // Repeat the same fragment after manually returning to Preview.
      for (let click = 0; click < 2; click++) {
        await page.getByRole('button', { name: 'Preview', exact: true }).click();
        await expect(page.locator('[data-file-code]')).toBeHidden();
        const oldURL = page.url();
        await page.locator('[data-file-preview]').getByRole('link', { name: label, exact: true }).click();
        await expect(page).toHaveURL(url + hash);
        await expectSourceLines(page, start, end);
        changes.push([oldURL, url + hash]);
      }
    }
    expect(await page.evaluate(() => (window as any).uxHashChanges)).toEqual(changes);
    expect(await page.evaluate(() => (window as any).uxDocument === document)).toBe(true);
    expect(requests).toEqual([]);
  });
}

test('direct source URLs, native hash history and ordinary anchors retain the document', async ({ page }) => {
  await login(page);
  for (const [hash, start, end] of [['#L180', 180, 180], ['#L180-L183', 180, 183], ['#L2', 2, 2]] as const) {
    await page.goto('/alice/demo/blob/preview-line-links/line-links.md' + hash);
    await expectSourceLines(page, start, end);
  }
  const url = page.url().split('#')[0];
  const requests: string[] = [];
  page.on('request', request => {
    if (request.isNavigationRequest() || request.headers()['accept'] === 'application/vnd.moonhub.page+json') requests.push(request.url());
  });
  await page.evaluate(() => {
    (window as any).uxDocument = document;
    (window as any).uxHashChanges = [];
    window.addEventListener('hashchange', event => (window as any).uxHashChanges.push([event.oldURL, event.newURL, event.isTrusted]));
  });
  await page.getByRole('button', { name: 'Preview', exact: true }).click();
  await page.locator('[data-file-preview]').getByRole('link', { name: 'Distant source', exact: true }).click();
  await expectSourceLines(page, 180);
  await page.getByRole('button', { name: 'Preview', exact: true }).click();
  await page.goBack();
  await expect(page).toHaveURL(url + '#L2');
  await expectSourceLines(page, 2);
  await page.getByRole('button', { name: 'Preview', exact: true }).click();
  await page.goForward();
  await expect(page).toHaveURL(url + '#L180');
  await expectSourceLines(page, 180);
  expect(await page.evaluate(() => (window as any).uxHashChanges)).toEqual([
    [url + '#L2', url + '#L180', false],
    [url + '#L180', url + '#L2', true],
    [url + '#L2', url + '#L180', true],
  ]);
  await page.getByRole('button', { name: 'Preview', exact: true }).click();
  await page.locator('[data-file-preview]').getByRole('link', { name: 'Back to top', exact: true }).click();
  await expect(page).toHaveURL(url + '#main-content');
  await expect(page.locator('[data-file-preview]')).toBeVisible();
  await expect(page.locator('[data-file-code]')).toBeHidden();
  await expect(page.locator('#main-content')).toBeFocused();
  await expect(page.locator('#main-content')).toBeInViewport();
  expect(await page.evaluate(() => (window as any).uxDocument === document)).toBe(true);
  expect(requests).toEqual([]);
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
  await native.locator('[data-file-finder] > summary').click();
  for (const width of [320, 390, 900, 1440]) {
    await native.setViewportSize({ width, height: 1000 });
    await expect(native.locator('.repository-releases')).toBeVisible();
    const panel = (await native.locator('.file-finder-panel').boundingBox())!;
    expect(panel.x).toBeGreaterThanOrEqual(20);
    expect(panel.x + panel.width).toBeLessThanOrEqual(width - 20);
    expect(await native.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    if (width <= 900) {
      const rail = (await native.locator('.repository-releases').boundingBox())!;
      const readme = (await native.locator('.readme-preview').boundingBox())!;
      expect(rail.y).toBeGreaterThan(readme.y + readme.height);
    }
  }
  await native.locator('[data-file-finder] > summary').click();
  await native.locator('.commit-history').click();
  await expect(native.locator('main')).toContainText('Commits');
  for (const width of [1280, 1440, 320]) {
    await native.setViewportSize({ width, height: 900 });
    const summary = native.locator('.repo-clone > summary');
    const clone = native.locator('.repo-clone-panel');
    await summary.click();
    await expect(clone.getByLabel('Clone with SSH')).toHaveValue('ssh://git@ssh.example.test:2222/alice/demo.git');
    const panel = (await clone.boundingBox())!;
    expect(panel.x).toBeGreaterThanOrEqual(20);
    expect(panel.x + panel.width).toBeLessThanOrEqual(width - 20);
    expect(panel.y).toBeGreaterThanOrEqual(0);
    expect(panel.y + panel.height).toBeLessThanOrEqual(900);
    await summary.click();
    await expect(clone).toBeHidden();
  }
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
    const links = await summary.locator('a[href*="/commit/"]').evaluateAll(links => links.map(a => a.getAttribute('href')));
    expect(links).toHaveLength(2);
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
    await expect(page.locator('.repository-releases')).toBeVisible();
    await expect(page.locator('.repo-clone > summary')).toBeVisible();
    await expect(page.locator('.branch-picker, .file-finder, .file-table')).toHaveCount(0);
    const firstPush = page.locator('.repository-first-push');
    await expect(firstPush.getByRole('link', { name: 'SSH keys' })).toHaveAttribute('href', '/-/settings/ssh-keys');
    await expect(firstPush.locator('code')).toHaveText("git push -- 'ssh://git@ssh.example.test:2222/alice/empty.git' 'HEAD:refs/heads/master'");
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
