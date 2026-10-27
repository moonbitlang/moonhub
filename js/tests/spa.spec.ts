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

test('authenticated navigation creates one issue, remounts editors and logs out without reloading', async ({ page }) => {
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
