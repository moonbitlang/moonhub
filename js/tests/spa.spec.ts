import { test, expect, type Page } from '@playwright/test';

async function hydrated(page: Page) {
  await expect(page.locator('html')).toHaveAttribute('data-hydrated', 'true');
}

test('hydration adopts SSR nodes and preserves input made before JavaScript loads', async ({ page }) => {
  const errors: string[] = [];
  page.on('pageerror', error => errors.push(error.message));
  let release!: () => void;
  const gate = new Promise<void>(resolve => { release = resolve; });
  await page.route('**/app-shell-*.mjs', async route => { await gate; await route.continue(); });
  await page.goto('/-/login', { waitUntil: 'commit' });
  await page.locator('main').waitFor();
  await page.evaluate(() => {
    const input = document.querySelector<HTMLInputElement>('input[name=name_key]')!;
    input.value = 'typed before hydration';
    (window as any).ssr = { main: document.querySelector('main'), input };
  });
  release();
  await hydrated(page);
  expect(await page.evaluate(() => {
    const ssr = (window as any).ssr;
    return { main: ssr.main === document.querySelector('main'), input: ssr.input === document.querySelector('input[name=name_key]'), value: ssr.input.value };
  })).toEqual({ main: true, input: true, value: 'typed before hydration' });
  await expect(page.locator('input[name=name_key]')).toHaveAttribute('autocomplete', 'username');
  expect(errors).toEqual([]);
});

test('SPA navigation, POST errors and browser history retain the current document', async ({ page }) => {
  const errors: string[] = [];
  const documents: string[] = [];
  page.on('pageerror', error => errors.push(error.message));
  page.on('request', request => { if (request.isNavigationRequest() && request.frame() === page.mainFrame()) documents.push(request.url()); });
  await page.goto('/-/login'); await hydrated(page);
  await page.evaluate(() => { (window as any).documentIdentity = document; });
  await page.getByRole('link', { name: 'Forgot password?' }).click();
  await expect(page).toHaveURL(/forgot-password$/);
  await expect(page.getByRole('heading', { name: 'Forgot password' })).toBeVisible();
  await page.goBack(); await expect(page.getByRole('heading', { name: 'Sign in' })).toBeVisible();
  await page.goForward(); await expect(page.getByRole('heading', { name: 'Forgot password' })).toBeVisible();
  await page.getByRole('link', { name: 'Back to sign in' }).click();
  await expect(page).toHaveURL(/login$/);
  let submissions = 0;
  page.on('request', request => { if (request.method() === 'POST' && new URL(request.url()).pathname === '/-/login') submissions++; });
  await page.locator('[name=name_key]').fill('does-not-exist');
  await page.locator('[name=password]').fill('wrong password');
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  await expect(page.getByRole('alert')).toContainText('Invalid username');
  await expect(page.locator('[name=name_key]')).toHaveValue('does-not-exist');
  await expect(page.locator('[name=password]')).toHaveValue('');
  expect(submissions).toBe(1);
  expect(await page.evaluate(() => (window as any).documentIdentity === document)).toBe(true);
  expect(documents).toHaveLength(1);
  expect(errors).toEqual([]);
});

test('SSR pages and native navigation remain usable without JavaScript', async ({ browser, baseURL }) => {
  const context = await browser.newContext({ javaScriptEnabled: false });
  const page = await context.newPage();
  await page.goto(baseURL + '/-/login');
  await expect(page.getByRole('heading', { name: 'Sign in' })).toBeVisible();
  await page.getByRole('link', { name: 'Forgot password?' }).click();
  await expect(page).toHaveURL(/forgot-password$/);
  await expect(page.locator('[name=email]')).toBeVisible();
  await context.close();
});

async function signIn(page: Page, name = 'alice') {
  await page.goto('/-/login');
  await hydrated(page);
  await page.locator('[name=name_key]').fill(name);
  await page.locator('[name=password]').fill('browser-test-password');
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  await expect(page).toHaveURL(/\/$/);
  await expect(page.locator('.account-identity')).toBeAttached();
}

test('header breadcrumbs navigate settings and remain available on mobile', async ({ page }) => {
  await signIn(page);
  const trail = page.getByRole('navigation', { name: 'Breadcrumb', exact: true });
  for (const [path, label] of [
    ['/-/admin/settings/mail', 'Email delivery'],
    ['/-/admin/pipelines/providers', 'Pipeline providers'],
    ['/-/settings/tokens', 'Access tokens'],
    ['/-/settings/ssh-keys', 'SSH keys'],
  ]) {
    await page.goto(path);
    await hydrated(page);
    await expect(trail.getByRole('link', { name: label, exact: true })).toHaveAttribute('aria-current', 'page');
    await expect(trail.locator('ol > li')).toHaveCount(3);
    await expect(trail.locator('a')).toHaveCount(3);
  }
  await page.goto('/-/admin/settings/mail');
  await hydrated(page);
  await trail.getByRole('link', { name: 'Site settings', exact: true }).click();
  await expect(page).toHaveURL(/admin\/settings\/ssh$/);
  await page.goto('/-/admin/settings/mail');
  await hydrated(page);
  for (const width of [390, 320]) {
    await page.setViewportSize({ width, height: 844 });
    await expect(trail).toBeVisible();
    await expect(trail.getByRole('link', { name: 'Administration', exact: true })).toBeVisible();
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    const header = (await page.locator('.site-header').boundingBox())!;
    const trailBounds = (await trail.boundingBox())!;
    expect(trailBounds.y + trailBounds.height).toBeLessThanOrEqual(header.y + header.height);
    const account = (await page.locator('summary[aria-label="Account menu"]').boundingBox())!;
    expect(account.y + account.height).toBeLessThanOrEqual(trailBounds.y);
    const target = trail.getByRole('link', { name: 'Administration', exact: true });
    expect((await target.boundingBox())!.height).toBeGreaterThanOrEqual(44);
  }
  await trail.getByRole('link', { name: 'Administration', exact: true }).click();
  await expect(page).toHaveURL(/admin\/settings\/ssh$/);
  await page.goto('/-/settings/tokens');
  await hydrated(page);
  await trail.getByRole('link', { name: 'Account', exact: true }).click();
  await expect(page).toHaveURL(/settings\/profile$/);
});

test('file breadcrumbs and parent links keep the revision through SPA and keyboard navigation', async ({ page }) => {
  const errors: string[] = [];
  page.on('pageerror', error => errors.push(error.message));
  await signIn(page);
  const directory = 'a-very-long-directory-name-for-narrow-mobile-navigation';
  const base = '/alice/demo/tree/feature/breadcrumbs';
  await page.goto(`/alice/demo/blob/feature/breadcrumbs/src/${directory}/main.mbt`);
  await hydrated(page);
  await page.evaluate(() => { (window as any).documentIdentity = document; });
  const trail = page.getByRole('navigation', { name: 'File path', exact: true });
  await expect(trail.locator('[aria-current=page]')).toHaveText('main.mbt');
  await trail.getByRole('link', { name: directory, exact: true }).click();
  await expect(page).toHaveURL(base + '/src/' + directory);
  await page.getByRole('link', { name: 'Parent directory', exact: true }).click();
  await expect(page).toHaveURL(base + '/src');
  // History changes before rendering and the navigation's focus reset finish.
  await expect(page.locator('html')).not.toHaveAttribute('aria-busy', 'true');
  const files = trail.getByRole('link', { name: 'Files', exact: true });
  await files.focus();
  await expect(files).toBeFocused();
  await page.keyboard.press('Enter');
  await expect(page).toHaveURL(base);
  expect(await page.evaluate(() => (window as any).documentIdentity === document)).toBe(true);
  await page.goto(`/alice/demo/blob/feature/breadcrumbs/src/${directory}/main.mbt`);
  await hydrated(page);
  for (const width of [390, 320]) {
    await page.setViewportSize({ width, height: 844 });
    await expect(trail.getByRole('link', { name: directory, exact: true })).toBeVisible();
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    const bounds = await trail.boundingBox();
    expect(bounds!.x + bounds!.width).toBeLessThanOrEqual(width);
  }
  expect(errors).toEqual([]);
});

test('file path links work with JavaScript disabled', async ({ browser, baseURL }) => {
  const context = await browser.newContext({ javaScriptEnabled: false, viewport: { width: 390, height: 844 } });
  const page = await context.newPage();
  await page.goto(baseURL + '/-/login');
  await page.locator('[name=name_key]').fill('alice');
  await page.locator('[name=password]').fill('browser-test-password');
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  await page.goto(baseURL + '/alice/demo/blob/feature/breadcrumbs/src/a-very-long-directory-name-for-narrow-mobile-navigation/main.mbt');
  await page.getByRole('navigation', { name: 'File path', exact: true }).getByRole('link', { name: 'src', exact: true }).click();
  await expect(page).toHaveURL(/tree\/feature\/breadcrumbs\/src$/);
  await page.getByRole('link', { name: 'Parent directory', exact: true }).click();
  await expect(page).toHaveURL(/tree\/feature\/breadcrumbs$/);
  await context.close();
});

test('authenticated navigation creates and edits one issue, remounts editors and logs out without reloading', async ({ page }) => {
  const errors: string[] = [];
  const documents: string[] = [];
  page.on('pageerror', error => errors.push(error.message));
  page.on('request', request => { if (request.isNavigationRequest() && request.frame() === page.mainFrame()) documents.push(request.url()); });
  await signIn(page);
  await page.evaluate(() => { (window as any).documentIdentity = document; });
  await page.locator('a[href="/alice/demo"]:visible').first().click();
  await expect(page.locator('#main-content')).toContainText('README');
  await page.getByRole('navigation', { name: 'Repository', exact: true }).getByRole('link', { name: 'Issues', exact: true }).click();
  await page.getByRole('link', { name: 'New issue', exact: true }).click();
  await expect(page.getByRole('heading', { name: 'New issue', exact: true })).toBeVisible();
  await expect(page.locator('.CodeMirror')).toHaveCount(1);
  await page.locator('[name=title]').fill('Hydrated issue');
  await page.locator('.CodeMirror').evaluate((node: any) => node.CodeMirror.setValue('**SPA description**'));
  await page.getByRole('button', { name: 'Preview', exact: true }).click();
  await expect(page.locator('.markdown-editor-preview strong')).toHaveText('SPA description');
  let created = 0;
  page.on('request', request => { if (request.method() === 'POST' && new URL(request.url()).pathname === '/alice/demo/issues') created++; });
  await page.getByRole('button', { name: 'Create issue', exact: true }).click();
  await expect(page).toHaveURL(/\/issues\/1$/);
  await expect(page.getByRole('heading', { name: /Hydrated issue/ })).toBeVisible();
  await expect(page.locator('.markdown-body strong').first()).toHaveText('SPA description');
  expect(created).toBe(1);
  await page.getByRole('link', { name: 'Edit issue', exact: true }).click();
  await expect(page.getByRole('heading', { name: 'Edit issue', exact: true })).toBeVisible();
  await expect(page.locator('[name=edit_version]')).toHaveValue('1');
  await page.locator('[name=title]').fill('Edited hydrated issue');
  await page.locator('.CodeMirror').evaluate((node: any) => node.CodeMirror.setValue('**Edited SPA description**'));
  await page.getByRole('combobox', { name: 'Assignee', exact: true }).selectOption('1');
  let edits = 0;
  page.on('request', request => { if (request.method() === 'POST' && new URL(request.url()).pathname === '/alice/demo/issues/1/edit') edits++; });
  await page.getByRole('button', { name: 'Save changes', exact: true }).click();
  await expect(page).toHaveURL(/\/issues\/1$/);
  await expect(page.getByRole('heading', { name: /Edited hydrated issue/ })).toBeVisible();
  await expect(page.locator('.discussion-description strong')).toHaveText('Edited SPA description');
  await expect(page.getByText('Opened by Alice · Assigned to Alice', { exact: true })).toBeVisible();
  expect(edits).toBe(1);
  await page.getByRole('link', { name: 'Edit issue', exact: true }).click();
  await expect(page.locator('[name=title]')).toHaveValue('Edited hydrated issue');
  await expect(page.locator('[name=description]')).toHaveValue('**Edited SPA description**');
  await expect(page.locator('[name=assignee]')).toHaveValue('1');
  await expect(page.locator('[name=edit_version]')).toHaveValue('2');
  await page.getByRole('navigation', { name: 'Repository', exact: true }).getByRole('link', { name: 'Issues', exact: true }).click();
  await page.getByRole('link', { name: 'New issue', exact: true }).click();
  await expect(page.locator('.CodeMirror')).toHaveCount(1);
  await expect(page.locator('.markdown-editor-toolbar')).toHaveCount(1);
  await page.locator('a[href="/alice/demo"]:visible').first().click();
  await expect(page.locator('.CodeMirror')).toHaveCount(0);
  await page.locator('a').filter({ hasText: 'README.md' }).first().click();
  await expect(page.locator('moonhub-file-view')).toBeVisible();
  await expect(page.locator('moonhub-file-view .moonhub-file-view')).toBeVisible();

  await page.locator('summary[aria-label="Account menu"]').click();
  await page.locator('.logout-form button').click();
  await expect(page.getByRole('heading', { name: 'Sign in', exact: true })).toBeVisible();
  expect(await page.evaluate(() => (window as any).documentIdentity === document)).toBe(true);
  expect(documents).toHaveLength(1);
  expect(errors).toEqual([]);
});

test('repository creation refreshes pending status and replaces it with the ready page', async ({ page }) => {
  const errors: string[] = [];
  const documents: string[] = [];
  page.on('pageerror', error => errors.push(error.message));
  page.on('request', request => { if (request.isNavigationRequest() && request.frame() === page.mainFrame()) documents.push(request.url()); });
  await signIn(page);
  await page.evaluate(() => { (window as any).documentIdentity = document; });
  await page.getByRole('link', { name: 'New repository', exact: true }).click();
  await expect(page.getByRole('heading', { name: 'New repository', exact: true })).toBeVisible();
  const historyBefore = await page.evaluate(() => history.state.moonhub);
  const name = 'spa-created';
  const statusPath = `/alice/-/repositories/${name}/status`;
  let statusReads = 0;
  let creations = 0;
  page.on('request', request => { if (request.method() === 'POST' && new URL(request.url()).pathname === '/alice/-/repositories') creations++; });
  await page.route(`**${statusPath}`, async route => {
    statusReads++;
    if (statusReads <= 2) {
      // Keep a real creation pending long enough to require more than one refresh.
      await route.fulfill({ status: 200, contentType: 'application/vnd.moonhub.page+json',
        headers: { Refresh: '2' },
        body: JSON.stringify({ head: [], body: [
          ['Element', 'main', [['id', 'main-content'], ['tabindex', '-1']], [
            ['Element', 'h1', [], [['Text', `alice/${name}`]]],
            ['Element', 'p', [['role', 'status']], [['Text', 'Preparing repository']]],
          ]],
        ] }),
      });
    } else await route.continue();
  });
  await page.getByLabel('Repository name', { exact: true }).fill(name);
  await page.getByRole('button', { name: 'Create repository', exact: true }).click();
  await expect(page).toHaveURL(statusPath);
  await expect(page.getByRole('status')).toHaveText('Preparing repository');
  await expect(page).toHaveURL(`/alice/${name}`, { timeout: 10000 });
  await expect(page.getByText('No files.', { exact: true })).toBeVisible();
  expect(statusReads).toBeGreaterThanOrEqual(3);
  expect(creations).toBe(1);
  expect(await page.evaluate(() => history.state.moonhub)).toBe(historyBefore + 1);
  expect(await page.evaluate(() => (window as any).documentIdentity === document)).toBe(true);
  expect(documents).toHaveLength(1);
  await page.goBack();
  await expect(page).toHaveURL('/alice/-/repositories/new');
  expect(errors).toEqual([]);
});

test('page refresh preserves scroll and history, then stops without a Refresh header', async ({ page }) => {
  await page.goto('/-/login'); await hydrated(page);
  await page.evaluate(() => { (window as any).documentIdentity = document; });
  let reads = 0;
  await page.route('**/-/forgot-password', async route => {
    reads++;
    await route.fulfill({ status: 200, contentType: 'application/vnd.moonhub.page+json',
      headers: reads === 1 ? { Refresh: '1' } : {},
      body: JSON.stringify({ head: [], body: [
        ['Element', 'main', [['id', 'main-content'], ['tabindex', '-1'], ['style', 'min-height:3000px']], [
          ['Element', 'h1', [], [['Text', reads === 1 ? 'Pending' : 'Finished']]],
        ]],
      ] }),
    });
  });
  await page.getByRole('link', { name: 'Forgot password?' }).click();
  await expect(page.getByRole('heading', { name: 'Pending', exact: true })).toBeVisible();
  await expect(page.locator('html')).not.toHaveAttribute('aria-busy');
  await page.evaluate(() => scrollTo(0, 500));
  const index = await page.evaluate(() => history.state.moonhub);
  await expect(page.getByRole('heading', { name: 'Finished', exact: true })).toBeAttached();
  expect(await page.evaluate(() => scrollY)).toBe(500);
  expect(await page.evaluate(() => history.state.moonhub)).toBe(index);
  expect(await page.evaluate(() => (window as any).documentIdentity === document)).toBe(true);
  await page.waitForTimeout(1200);
  expect(reads).toBe(2);
  await page.goBack();
  await expect(page.getByRole('heading', { name: 'Sign in', exact: true })).toBeVisible();
});

test('leaving a refreshing page cancels its pending refresh', async ({ page }) => {
  await page.goto('/-/login'); await hydrated(page);
  let reads = 0;
  await page.route('**/-/forgot-password', async route => {
    reads++;
    const response = await route.fetch();
    await route.fulfill({ response, headers: { ...response.headers(), Refresh: '1' } });
  });
  await page.getByRole('link', { name: 'Forgot password?' }).click();
  await expect(page.getByRole('heading', { name: 'Forgot password', exact: true })).toBeVisible();
  await page.getByRole('link', { name: 'Back to sign in', exact: true }).click();
  await expect(page.getByRole('heading', { name: 'Sign in', exact: true })).toBeVisible();
  let requestsAfterLeaving = 0;
  page.on('request', request => { if (request.headers()['accept'] === 'application/vnd.moonhub.page+json') requestsAfterLeaving++; });
  await page.waitForTimeout(1200);
  expect(reads).toBe(1);
  expect(requestsAfterLeaving).toBe(0);
});

for (const [status, refresh] of [[200, '0'], [200, '1; url=https://example.com'], [200, '2147484'], [500, '1']] as const) {
  test(`page status ${status} with Refresh ${refresh} does not start a refresh`, async ({ page }) => {
    await page.goto('/-/login'); await hydrated(page);
    let reads = 0;
    await page.route('**/-/forgot-password', async route => {
      reads++;
      const response = await route.fetch();
      await route.fulfill({ response, status, headers: { ...response.headers(), Refresh: refresh } });
    });
    await page.getByRole('link', { name: 'Forgot password?' }).click();
    await expect(page.getByRole('heading', { name: 'Forgot password', exact: true })).toBeVisible();
    await page.waitForTimeout(1200);
    expect(reads).toBe(1);
  });
}

test('Markdown references agree between preview and saved content and navigate without reloading', async ({ page }) => {
  const errors: string[] = [];
  page.on('pageerror', error => errors.push(error.message));
  await signIn(page);
  await page.goto('/alice/demo/issues/new');
  await hydrated(page);
  await page.locator('[name=title]').fill('Markdown link target');
  await page.getByRole('button', { name: 'Create issue', exact: true }).click();
  await expect(page.getByRole('heading', { name: /Markdown link target/ })).toBeVisible();
  const targetPath = new URL(page.url()).pathname;
  const reference = '#' + targetPath.split('/').pop();
  await page.goto('/alice/demo/issues/new');
  await hydrated(page);
  await page.locator('[name=title]').fill('Markdown references');
  await page.locator('.CodeMirror').evaluate((node: any, ref) => node.CodeMirror.setValue(`See ${ref} and !12; code: \`\`#56 \` !78\`\`.`), reference);
  await page.getByRole('button', { name: 'Preview', exact: true }).click();
  const preview = page.locator('.markdown-editor-preview');
  await expect(preview.getByRole('link', { name: reference, exact: true })).toHaveAttribute('href', targetPath);
  await expect(preview.getByRole('link', { name: '!12', exact: true })).toHaveAttribute('href', '/alice/demo/merge-requests/12');
  await expect(preview.locator('code')).toHaveText('#56 ` !78');
  await expect(preview.locator('code a')).toHaveCount(0);
  await page.getByRole('button', { name: 'Create issue', exact: true }).click();
  await expect(page.getByRole('heading', { name: /Markdown references/ })).toBeVisible();
  const description = page.locator('.discussion-description');
  await expect(description.getByRole('link', { name: reference, exact: true })).toHaveAttribute('href', targetPath);
  await expect(description.getByRole('link', { name: '!12', exact: true })).toHaveAttribute('href', '/alice/demo/merge-requests/12');
  await expect(description.locator('code')).toHaveText('#56 ` !78');
  await expect(description.locator('code a')).toHaveCount(0);
  await page.evaluate(() => { (window as any).documentIdentity = document; });
  await description.getByRole('link', { name: reference, exact: true }).click();
  await expect(page).toHaveURL(new URL(targetPath, page.url()).href);
  await expect(page.getByRole('heading', { name: /Markdown link target/ })).toBeVisible();
  expect(await page.evaluate(() => (window as any).documentIdentity === document)).toBe(true);
  expect(errors).toEqual([]);
});

test('SPA page responses retain private repository authorization and CSRF enforcement', async ({ page }) => {
  await signIn(page, 'outsider');
  const privateResponse = await page.request.get('/alice/demo', { headers: { Accept: 'application/vnd.moonhub.page+json' } });
  expect(privateResponse.status()).toBe(404);
  expect(privateResponse.headers()['cache-control']).toContain('no-store');
  expect(privateResponse.headers()['content-type']).toBe('application/vnd.moonhub.page+json');
  expect(await privateResponse.text()).not.toContain('README.md');
  await page.context().clearCookies();
  await signIn(page);
  const csrfResponse = await page.request.post('/alice/demo/issues', {
    headers: { Accept: 'application/vnd.moonhub.page+json' },
    form: { title: 'Must not be created', description: '', assignee: '0', csrf_token: 'invalid' },
  });
  expect(csrfResponse.status()).toBe(403);
  await page.goto('/alice/demo/issues');
  await expect(page.getByText('Must not be created', { exact: true })).toHaveCount(0);
});

test('latest navigation wins and blocked history restores without fetching another page', async ({ page }) => {
  await page.goto('/-/login'); await hydrated(page);
  let release!: () => void;
  let intercepted!: () => void;
  const gate = new Promise<void>(resolve => { release = resolve; });
  const started = new Promise<void>(resolve => { intercepted = resolve; });
  await page.route('**/-/forgot-password', async route => {
    const response = await route.fetch();
    intercepted(); await gate;
    await route.fulfill({ response }).catch(() => {});
  });
  await page.getByRole('link', { name: 'Forgot password?' }).click();
  await started;
  await page.getByRole('link', { name: 'Forgot password?' }).evaluate(link => {
    const next = document.createElement('a'); next.href = '/-/reset-password';
    link.after(next); next.click(); next.remove();
  });
  await expect(page.getByRole('heading', { name: 'Reset password', exact: true })).toBeVisible();
  release();
  await expect(page).toHaveURL(/reset-password$/);
  await page.waitForFunction(() => !document.documentElement.hasAttribute('aria-busy'));
  await page.evaluate(() => {
    document.addEventListener('moonhub:before-navigate', event => event.preventDefault(), { once: true });
  });
  let fetched = 0;
  page.on('request', request => { if (request.headers()['accept'] === 'application/vnd.moonhub.page+json') fetched++; });
  await page.goBack();
  await expect(page).toHaveURL(/reset-password$/);
  await expect(page.getByRole('heading', { name: 'Reset password', exact: true })).toBeVisible();
  expect(fetched).toBe(0);
});

test('a lost POST response preserves entered text and never replays the mutation', async ({ page }) => {
  await page.goto('/-/login'); await hydrated(page);
  await page.locator('[name=name_key]').fill('unsent-user');
  await page.locator('[name=password]').fill('unsent-password');
  let posts = 0;
  await page.route('**/-/login', async route => {
    if (route.request().method() === 'POST') { posts++; await route.abort('failed'); }
    else await route.continue();
  });
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  await expect(page.getByRole('alert')).toContainText('Check the page before submitting again');
  await expect(page.locator('[name=name_key]')).toHaveValue('unsent-user');
  await expect(page.locator('[name=password]')).toHaveValue('unsent-password');
  await expect(page.locator('form[aria-busy]')).toHaveCount(0);
  expect(posts).toBe(1);
});

test('direct authenticated visits hydrate editors and code views, and anchors retain the document', async ({ page }) => {
  const errors: string[] = [];
  page.on('pageerror', error => errors.push(error.message));
  await signIn(page);
  await page.goto('/alice/demo/issues/new'); await hydrated(page);
  await expect(page.locator('.CodeMirror')).toHaveCount(1);
  await page.goto('/alice/demo/blob/master/README.md'); await hydrated(page);
  await expect(page.locator('moonhub-file-view .moonhub-file-view')).toBeVisible();
  await page.evaluate(() => { (window as any).documentIdentity = document; });
  await page.getByRole('link', { name: 'Skip to content' }).focus();
  await page.getByRole('link', { name: 'Skip to content' }).press('Enter');
  await expect(page).toHaveURL(/#main-content$/);
  await page.goBack();
  await expect(page).not.toHaveURL(/#/);
  await page.goForward();
  await expect(page).toHaveURL(/#main-content$/);
  expect(await page.evaluate(() => (window as any).documentIdentity === document)).toBe(true);
  expect(errors).toEqual([]);
});

for (const action of ['forward', 'anchor'] as const) {
  test(`returning to the mounted page cancels a pending history fetch via ${action}`, async ({ page }) => {
    const errors: string[] = [];
    page.on('pageerror', error => errors.push(error.message));
    await page.goto('/-/login'); await hydrated(page);
    await page.evaluate(() => { (window as any).documentIdentity = document; });
    await page.getByRole('link', { name: 'Forgot password?' }).click();
    await expect(page.getByRole('heading', { name: 'Forgot password', exact: true })).toBeVisible();
    await expect(page.locator('html')).not.toHaveAttribute('aria-busy');
    await page.evaluate(() => {
      const next = document.createElement('a'); next.href = '/-/reset-password';
      document.body.append(next); next.click(); next.remove();
    });
    await expect(page.getByRole('heading', { name: 'Reset password', exact: true })).toBeVisible();
    await expect(page.locator('html')).not.toHaveAttribute('aria-busy');

    let release!: () => void;
    let intercepted!: () => void;
    let fulfilled!: () => void;
    const gate = new Promise<void>(resolve => { release = resolve; });
    const started = new Promise<void>(resolve => { intercepted = resolve; });
    const completed = new Promise<void>(resolve => { fulfilled = resolve; });
    await page.route('**/-/forgot-password', async route => {
      const response = await route.fetch();
      intercepted(); await gate;
      await route.fulfill({ response }).catch(() => {});
      fulfilled();
    });
    await page.goBack(); await started;
    await expect(page).toHaveURL(/forgot-password$/);
    if (action === 'forward') await page.goForward();
    else await page.evaluate(() => {
      const anchor = document.createElement('a'); anchor.href = '/-/reset-password#main-content';
      document.body.append(anchor); anchor.click(); anchor.remove();
    });
    await expect(page).toHaveURL(action === 'forward' ? /reset-password$/ : /reset-password#main-content$/);
    // Cancellation clears busy immediately, before the delayed response arrives.
    await expect(page.locator('html')).not.toHaveAttribute('aria-busy');
    release(); await completed;
    await expect(page.getByRole('heading', { name: 'Reset password', exact: true })).toBeVisible();
    expect(await page.evaluate(() => history.state.moonhub)).toBe(2);
    await page.unroute('**/-/forgot-password');
    await page.goBack();
    await expect(page.getByRole('heading', { name: 'Forgot password', exact: true })).toBeVisible();
    await expect(page.locator('html')).not.toHaveAttribute('aria-busy');
    expect(await page.evaluate(() => history.state.moonhub)).toBe(1);
    await page.goForward();
    await expect(page.getByRole('heading', { name: 'Reset password', exact: true })).toBeVisible();
    await expect(page.locator('html')).not.toHaveAttribute('aria-busy');
    expect(await page.evaluate(() => (window as any).documentIdentity === document)).toBe(true);
    expect(errors).toEqual([]);
  });
}


test('MR target edits preserve history and work on desktop and mobile without JavaScript', async ({ browser, baseURL }) => {
  for (const javaScriptEnabled of [true, false]) {
    const context = await browser.newContext({ javaScriptEnabled, viewport: { width: 1440, height: 1000 } });
    const page = await context.newPage();
    await page.goto(baseURL + '/-/login');
    if (javaScriptEnabled) await hydrated(page);
    await page.locator('[name=name_key]').fill('alice');
    await page.getByLabel('Password', { exact: true }).fill('browser-test-password');
    await page.getByRole('button', { name: 'Sign in', exact: true }).click();
    await expect(page).toHaveURL(/\/$/);
    await page.goto(baseURL + '/alice/demo/merge-requests/new');
    if (javaScriptEnabled) await hydrated(page);
    await page.locator('select[name=source]').selectOption('feature/breadcrumbs');
    await page.locator('select[name=target]').selectOption('master');
    await page.getByLabel('Title', { exact: true }).fill('Change target browser fixture');
    await page.getByRole('button', { name: 'Create merge request', exact: true }).click();
    await expect(page).toHaveURL(/merge-requests\/\d+$/);
    const detail = page.url();
    await page.locator('.mr-more-actions > summary').click();
    const form = page.locator('form[action$="/retarget"]');
    const target = form.getByRole('combobox', { name: 'Target branch', exact: true });
    await expect(target).toBeVisible();
    await expect(target.locator('option[value="feature/breadcrumbs"]')).toHaveCount(0);
    await target.selectOption('release');
    for (const width of [1440, 390]) {
      await page.setViewportSize({ width, height: 1000 });
      if (width < 600 && javaScriptEnabled) {
        await page.waitForFunction(() => document.querySelector('#app-sidebar')!.getBoundingClientRect().right <= 1);
      }
      await expect(form.getByRole('button', { name: 'Change target branch' })).toBeVisible();
      expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
      await page.screenshot({ path: `test-results/mr-target-${javaScriptEnabled ? 'spa' : 'native'}-${width}.png`, fullPage: true });
    }
    await form.getByRole('button', { name: 'Change target branch' }).click();
    await expect(page.locator('.mr-branch-summary')).toContainText('into release');
    await expect(page.locator('#mr-version')).toHaveValue('2');
    await page.goto(detail + '?version=1');
    await expect(page.locator('.mr-branch-summary')).toContainText('into master');
    await expect(page.locator('form[action$="/retarget"]')).toHaveCount(0);
    // Close the fixture so the no-script pass may create the same source/target pair.
    await page.goto(detail);
    await page.locator('.mr-more-actions > summary').click();
    await page.getByRole('button', { name: 'Close', exact: true }).click();
    await context.close();
  }
});
