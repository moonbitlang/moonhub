import { test, expect, type Page } from '@playwright/test';
import { mkdir } from 'node:fs/promises';

async function signIn(page: Page, hydrate = true) {
  await page.goto('/-/login');
  await page.locator('[name=name_key]').fill('alice');
  await page.getByLabel('Password', { exact: true }).fill('browser-test-password');
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  await expect(page).toHaveURL(/\/$/);
  if (hydrate) await expect(page.locator('html')).toHaveAttribute('data-hydrated', 'true');
}

test('account time zones survive SPA navigation and a second device, then reset to device time', async ({ browser, baseURL }) => {
  const context = await browser.newContext({ baseURL, locale: 'en-GB', timezoneId: 'America/Los_Angeles' });
  const page = await context.newPage();
  const errors: string[] = [];
  page.on('pageerror', error => errors.push(error.message));
  await signIn(page);
  await page.goto('/-/settings/profile');
  const zone = page.getByLabel('Display time zone', { exact: true });
  await expect(zone).toHaveValue('');
  await expect(page.locator('[data-time-zone-preview]')).toContainText('America/Los_Angeles');
  await zone.selectOption('Asia/Kathmandu');
  await expect(page.locator('[data-time-zone-preview]')).toContainText('Asia/Kathmandu');
  await page.getByRole('button', { name: 'Save profile' }).click();
  await expect(page.getByRole('status').first()).toHaveText('Profile saved.');
  await expect(page.locator('main')).toHaveAttribute('data-time-zone', 'Asia/Kathmandu');
  await page.goto('/alice/demo/issues/new');
  await page.getByLabel('Title', { exact: true }).fill('Display time zone browser regression');
  await page.getByRole('button', { name: 'Create issue', exact: true }).click();
  await expect(page).toHaveURL(/\/issues\/\d+$/);
  const issueURL = page.url();
  const activity = page.locator('.mr-timeline time').first();
  await expect(activity).toHaveAttribute('datetime', /T.*Z$/);
  await expect(activity).toContainText('(Asia/Kathmandu)');
  await expect(activity).toHaveAttribute('title', /Asia\/Kathmandu/);
  const second = await browser.newContext({ baseURL, locale: 'en-GB', timezoneId: 'Europe/Berlin', storageState: await context.storageState() });
  const other = await second.newPage();
  await other.goto(issueURL);
  await expect(other.locator('.mr-timeline time').first()).toHaveText(await activity.textContent() ?? '');
  await second.close();
  await page.goto('/-/settings/profile');
  await expect(zone).toHaveValue('Asia/Kathmandu');
  await mkdir('../.impeccable/review', { recursive: true });
  for (const [name, width] of [['desktop', 1440], ['mobile', 390]] as const) {
    await page.setViewportSize({ width, height: 1000 });
    if (width < 900) {
      await expect.poll(() => page.locator('#app-sidebar').evaluate(sidebar => sidebar.getBoundingClientRect().right)).toBeLessThanOrEqual(1);
    }
    await expect(zone).toBeVisible();
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    await page.screenshot({ path: `../.impeccable/review/timezone-${name}.png`, fullPage: true });
  }
  await zone.selectOption('');
  await page.getByRole('button', { name: 'Save profile' }).click();
  await expect(page.locator('main')).toHaveAttribute('data-time-zone', '');
  await page.goto(issueURL);
  await expect(activity).toContainText('(America/Los_Angeles)');
  expect(errors).toEqual([]);
  await context.close();
});

for (const preference of ['', 'Asia/Kathmandu', 'Unknown/Zone']) {
  test(`timestamps handle DST, offsets, calendar dates and relative time for preference ${preference || 'device'}`, async ({ browser, baseURL }) => {
    const context = await browser.newContext({ baseURL, locale: 'en-GB', timezoneId: 'America/Los_Angeles' });
    const page = await context.newPage();
    await page.clock.install({ time: new Date('2024-03-10T10:30:00Z') });
    await page.goto('/-/login');
    await expect(page.locator('html')).toHaveAttribute('data-hydrated', 'true');
    await page.route('**/-/forgot-password', route => route.fulfill({
      contentType: 'application/vnd.moonhub.page+json',
      body: JSON.stringify({ head: [], body: [
        ['Element', 'main', [['id', 'main-content'], ['data-time-zone', preference]], [
          ...[
            ['before', '2024-03-10T09:30:00Z', false],
            ['after', '2024-03-10T10:30:00Z', false],
            ['offset', '2024-03-10T11:30:00+01:00', false],
            ['relative', '2024-03-10T09:30:00Z', true],
          ].map(([id, instant, relative]) => ['Element', 'time', [
            ['id', id], ['datetime', instant], ['data-local-time', ''], ...(relative ? [['data-relative-time', '']] : []),
          ], [['Text', 'UTC fallback']]]),
          ['Element', 'time', [['id', 'invalid'], ['datetime', 'invalid'], ['data-local-time', '']], [['Text', 'Invalid fallback']]],
          ['Element', 'span', [['id', 'calendar-date']], [['Text', '2024-03-10']]],
        ]],
      ] }),
    }));
    await page.getByRole('link', { name: 'Forgot password?' }).click();
    const expected = preference === 'Asia/Kathmandu' ? ['15:15:00', '16:15:00', 'Asia/Kathmandu']
      : preference ? ['09:30:00', '10:30:00', 'UTC'] : ['01:30:00', '03:30:00', 'America/Los_Angeles'];
    await expect(page.locator('#before')).toContainText(expected[0]);
    await expect(page.locator('#after')).toContainText(expected[1]);
    await expect(page.locator('#after')).toContainText(`(${expected[2]})`);
    await expect(page.locator('#offset')).toHaveText(await page.locator('#after').textContent() ?? '');
    await expect(page.locator('#relative')).toHaveText('1 hour ago');
    await expect(page.locator('#relative')).toHaveAttribute('title', new RegExp(expected[0]));
    await expect(page.locator('#invalid')).toHaveText('Invalid fallback');
    await expect(page.locator('#calendar-date')).toHaveText('2024-03-10');
    await page.clock.fastForward(60000);
    await expect(page.locator('#relative')).toHaveText('1 hour ago');
    await context.close();
  });
}

test('native profile settings save preferences and timestamp fallbacks remain explicit without JavaScript', async ({ browser, baseURL }) => {
  const context = await browser.newContext({ baseURL, javaScriptEnabled: false });
  const page = await context.newPage();
  await signIn(page, false);
  await page.goto('/-/settings/profile');
  const zone = page.getByLabel('Display time zone', { exact: true });
  await zone.selectOption('Asia/Shanghai');
  await page.getByRole('button', { name: 'Save profile' }).click();
  await expect(zone).toHaveValue('Asia/Shanghai');
  await page.goto('/alice/demo/issues/new');
  await page.getByLabel('Title', { exact: true }).fill('UTC fallback without JavaScript');
  await page.getByRole('button', { name: 'Create issue', exact: true }).click();
  await expect(page.locator('.mr-timeline time').first()).toHaveText(/ UTC$/);
  await page.goto('/-/settings/profile');
  await zone.selectOption('');
  await page.getByRole('button', { name: 'Save profile' }).click();
  await context.close();
});
