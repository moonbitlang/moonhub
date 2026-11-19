import { test, expect } from '@playwright/test';

for (const javaScriptEnabled of [true, false]) {
  for (const width of [1440, 390]) {
    test(`Danger Zone confirmations at ${width}px with JavaScript ${javaScriptEnabled}`, async ({ browser, baseURL }) => {
      test.setTimeout(60000);
      const context = await browser.newContext({ javaScriptEnabled, viewport: { width, height: 900 } });
      const anonymous = await browser.newContext();
      const page = await context.newPage();
      const errors: string[] = [];
      const documents: string[] = [];
      page.on('request', request => { if (request.isNavigationRequest() && request.frame() === page.mainFrame()) documents.push(new URL(request.url()).pathname); });
      page.on('pageerror', error => errors.push(error.message));
      const name = `danger-${width}-${javaScriptEnabled}-${Date.now()}`;
      const repo = `/alice/${name}`;
      const base = `${repo}/settings/danger-zone`;
      try {
        await page.goto(baseURL + '/-/login');
        if (javaScriptEnabled) await expect(page.locator('html')).toHaveAttribute('data-hydrated', 'true');
        await page.locator('[name=name_key]').fill('alice');
        await page.locator('[name=password]').fill('browser-test-password');
        await page.getByRole('button', { name: 'Sign in', exact: true }).click();
        await expect(page).toHaveURL(baseURL + '/', { timeout: 15000 });
        await page.goto(baseURL + '/alice/-/repositories/new');
        await page.getByLabel('Repository name', { exact: true }).fill(name);
        await page.getByRole('button', { name: 'Create repository', exact: true }).click();
        await expect(page).toHaveURL(baseURL + repo, { timeout: 15000 });
        await page.locator('.repository-tabs').getByRole('link', { name: 'Settings', exact: true }).click();
        if (javaScriptEnabled) {
          await expect(page.locator('html')).toHaveAttribute('data-hydrated', 'true');
          await page.evaluate(() => { (window as any).dangerDocument = document; });
          documents.length = 0;
          if (width === 390) await page.getByRole('button', { name: 'Open navigation', exact: true }).click();
        }
        const danger = page.locator('#app-sidebar').getByRole('link', { name: 'Danger Zone', exact: true });
        await expect(danger).toBeVisible();
        await expect(page.locator('.sidebar-footer .sidebar-danger')).toContainText('Danger Zone');
        await expect(page.locator('[data-sidebar-collapse]')).toHaveCount(0);
        await danger.click();
        await expect(page).toHaveURL(baseURL + base);
        await expect(page.locator('.breadcrumbs')).toContainText('Danger Zone');
        await expect(page.locator('.repository-tabs [aria-current]')).toHaveText('Settings');
        await expect(page.locator('.sidebar-danger a')).toHaveAttribute('aria-current', 'page');
        await expect(page.locator('[data-sidebar-collapse]')).toHaveCount(0);
        if (javaScriptEnabled) expect(await page.evaluate(() => (window as any).dangerDocument === document)).toBe(true);
        await expect(page.locator('.danger-zone')).toContainText('currently private');
        if (javaScriptEnabled) {
          await page.screenshot({ path: `test-results/danger-zone-${width}.png`, fullPage: true });
          if (width === 390) {
            await page.getByRole('button', { name: 'Open navigation', exact: true }).click();
            await page.screenshot({ path: 'test-results/danger-zone-mobile-sidebar.png', fullPage: true });
            await page.keyboard.press('Escape');
          }
        }
        await page.getByRole('link', { name: 'Change visibility', exact: true }).click();
        await expect(page.locator('main')).toContainText('including people who are not signed in');
        await page.getByRole('link', { name: 'Cancel', exact: true }).click();
        await expect(page).toHaveURL(baseURL + base);
        for (const [visibility, status] of [['public', 200], ['private', 404]] as const) {
          await page.getByRole('link', { name: 'Change visibility', exact: true }).click();
          await page.getByRole('button', { name: 'Confirm visibility change', exact: true }).click();
          await expect(page).toHaveURL(baseURL + base);
          await expect(page.locator('.danger-zone')).toContainText(`currently ${visibility}`);
          expect((await anonymous.request.get(baseURL + repo)).status()).toBe(status);
        }
        await page.getByRole('link', { name: 'Delete repository', exact: true }).click();
        await expect(page.locator('main')).toContainText('Deploy keys will be revoked');
        await page.getByRole('link', { name: 'Cancel', exact: true }).click();
        await expect(page).toHaveURL(baseURL + base);
        await page.getByRole('link', { name: 'Delete repository', exact: true }).click();
        await page.getByLabel(`Type alice/${name} to confirm`, { exact: true }).fill('wrong/repository');
        await page.getByRole('button', { name: 'Delete this repository', exact: true }).click();
        await expect(page.getByRole('alert')).toContainText('Enter the full repository name exactly');
        await expect(page.locator('[name=confirmation]')).toHaveValue('wrong/repository');
        await page.locator('[name=confirmation]').fill(`alice/${name}`);
        await page.getByRole('button', { name: 'Delete this repository', exact: true }).click();
        await expect(page).toHaveURL(baseURL + '/alice');
        expect((await context.request.get(baseURL + repo)).status()).toBe(404);
        if (javaScriptEnabled) {
          expect(documents).toEqual([]);
          expect(await page.evaluate(() => (window as any).dangerDocument === document)).toBe(true);
        }
        expect(errors).toEqual([]);
      } finally {
        await anonymous.close();
        await context.close();
      }
    });
  }
}
