const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require('playwright');

const output = path.resolve(__dirname, '../_build/ui-browser');
const preview = JSON.parse(fs.readFileSync(path.join(output, 'preview.json'), 'utf8'));

async function frame(page) {
  return page.evaluate(() => {
    const bounds = selector => {
      const element = document.querySelector(selector);
      if (!element) return null;
      const rect = element.getBoundingClientRect();
      return { x: rect.x, y: rect.y, width: rect.width, height: rect.height, visibility: getComputedStyle(element).visibility };
    };
    return {
      sidebar: bounds('.sidebar'), main: bounds('main'), brand: bounds('.brand'),
      toolbar: bounds('.list-toolbar'), list: bounds('.repository-list'),
      search: bounds('[data-filter-control]'), collapse: bounds('[data-sidebar-collapse]'),
      missingIcons: [...document.querySelectorAll('[data-icon]')]
        .filter(element => getComputedStyle(element, '::before').maskImage === 'none')
        .map(element => element.dataset.icon),
    };
  });
}

async function authenticate(context) {
  const response = await context.request.post(preview.url + '/login', {
    form: { name_key: preview.username, password: preview.password }, maxRedirects: 0,
  });
  assert.equal(response.status(), 303);
}

async function verifyDelayedShell(browser, scenario) {
  const context = await browser.newContext({ viewport: { width: scenario.width, height: 900 } });
  try {
    await authenticate(context);
    if (scenario.collapsed) await context.addInitScript(() => localStorage.setItem('moonhub.sidebar', 'collapsed'));
    if (scenario.storageBlocked) await context.addInitScript(() => {
      Object.defineProperty(window, 'localStorage', { get() { throw new DOMException('Storage unavailable', 'SecurityError'); } });
    });
    const page = await context.newPage();
    page.setDefaultTimeout(15000);
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    const results = [];
    for (const route of ['/', '/-/teams', '/moonhub?tab=members', '/moonhub/moonhub', '/-/settings/ssh-keys']) {
      let release;
      const gate = new Promise(resolve => { release = resolve; });
      const hold = async request => { await gate; await request.continue(); };
      await page.route('**/assets/app-shell-*.mjs', hold);
      try {
        await page.goto(preview.url + route, { waitUntil: 'commit' });
        await page.waitForFunction(() => document.readyState !== 'loading');
        await page.locator('main').waitFor();
        const before = await frame(page);
        assert.deepEqual(before.missingIcons, [], `${scenario.name} ${route}: initial icons`);
        assert.equal(before.main.y, 56, `${scenario.name} ${route}: initial content position`);
        if (scenario.width > 900) assert.equal(before.sidebar.width, scenario.collapsed ? 64 : 224);
        else assert.equal(before.sidebar.visibility, 'hidden');
        if (route === '/') {
          assert(before.search.height > 0, 'search space must exist before enhancement');
          assert(await page.locator('[data-filter-control]').evaluate(element => element.inert));
          await page.screenshot({ path: path.join(output, `loading-${scenario.name}-before.png`) });
        }
        release();
        await page.waitForFunction(() => document.documentElement.dataset.uiReady === 'true');
        const after = await frame(page);
        assert.deepEqual(after, before, `${scenario.name} ${route}: enhancement must not shift the frame`);
        if (route === '/') {
          assert(!await page.locator('[data-filter-control]').evaluate(element => element.inert));
          await page.getByLabel('Find a repository').fill('runtime');
          assert.equal(await page.locator('[data-filter-item]:visible').count(), 1);
          await page.getByLabel('Find a repository').fill('');
          await page.screenshot({ path: path.join(output, `loading-${scenario.name}-after.png`) });
        }
        results.push({ scenario: scenario.name, route, before, after });
      } finally {
        release();
        await page.unroute('**/assets/app-shell-*.mjs', hold);
      }
    }
    assert.deepEqual(errors, []);
    return results;
  } finally { await context.close(); }
}

async function verifyFallback(browser, scriptsEnabled) {
  const context = await browser.newContext({ javaScriptEnabled: scriptsEnabled, viewport: { width: 390, height: 844 } });
  try {
    await authenticate(context);
    const page = await context.newPage();
    if (scriptsEnabled) await page.route('**/assets/app-shell-*.mjs', request => request.abort());
    await page.goto(preview.url + '/');
    assert.equal(await page.locator('html').getAttribute('data-ui-enhanced'), null);
    assert.equal(await page.locator('html').getAttribute('data-sidebar-collapsed'), null);
    await page.locator('.sidebar').waitFor({ state: 'visible' });
    assert(!await page.locator('[data-filter-control]').isVisible());
    assert(!await page.locator('[data-sidebar-open]').isVisible());
    assert.deepEqual((await frame(page)).missingIcons, []);
    await page.locator('.sidebar').getByRole('link', { name: 'Teams', exact: true }).click();
    await page.waitForURL(preview.url + '/-/teams');
    await page.getByRole('heading', { name: 'Teams', exact: true }).waitFor();
  } finally { await context.close(); }
}

(async () => {
  const browser = await chromium.launch({ headless: true });
  try {
    const results = [];
    for (const scenario of [
      { name: 'desktop', width: 1400 }, { name: 'collapsed', width: 1400, collapsed: true },
      { name: 'mobile', width: 390 }, { name: 'storage-blocked', width: 390, storageBlocked: true },
    ]) results.push(...await verifyDelayedShell(browser, scenario));
    await verifyFallback(browser, false);
    await verifyFallback(browser, true);
    fs.writeFileSync(path.join(output, 'loading-report.json'), JSON.stringify({ passed: true, results, fallbacks: ['no-javascript', 'script-failure'] }, null, 2));
    console.log(`Loading smoke passed: ${results.length} delayed-script navigations without layout shifts or missing icons; no-JavaScript and failed-script navigation works.`);
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
