import { test, expect } from '@playwright/test';

for (const javaScriptEnabled of [true, false]) {
  for (const width of [1440, 390]) {
    test(`anonymous public browsing at ${width}px with JavaScript ${javaScriptEnabled}`, async ({ browser, baseURL }) => {
      const context = await browser.newContext({ javaScriptEnabled, viewport: { width, height: 900 } });
      const page = await context.newPage();
      const errors: string[] = [];
      page.on('pageerror', error => errors.push(error.message));
      try {
        for (const path of ['/', '/alice']) {
          expect((await page.goto(baseURL + path))?.status()).toBe(200);
          await expect(page.locator('a[href="/alice/public"]').first()).toBeVisible();
          await expect(page.getByRole('link', { name: 'demo', exact: true })).toHaveCount(0);
        }
        expect((await page.goto(baseURL + '/alice/public'))?.status()).toBe(200);
        if (javaScriptEnabled) {
          await expect(page.locator('html')).toHaveAttribute('data-hydrated', 'true');
          await page.evaluate(() => { (window as any).publicDocument = document; });
        }
        const signIn = page.getByRole('banner').getByRole('link', { name: 'Sign in', exact: true });
        await expect(signIn).toBeVisible();
        const bounds = await signIn.boundingBox();
        expect(bounds).not.toBeNull();
        expect(bounds!.x).toBeGreaterThanOrEqual(0);
        expect(bounds!.x + bounds!.width).toBeLessThanOrEqual(width);
        if (width === 390) expect(bounds!.height).toBeGreaterThanOrEqual(44);
        if (javaScriptEnabled) await page.screenshot({ path: `test-results/public-repository-${width}.png`, fullPage: true });
        await page.getByRole('link', { name: 'src', exact: true }).click();
        await expect(page).toHaveURL(/public\/tree\/master\/src$/);
        await page.getByRole('link', { name: 'main.mbt', exact: true }).click();
        await expect(page).toHaveURL(/public\/blob\/master\/src\/main.mbt$/);
        await expect(page.locator('moonhub-file-view')).toContainText('println("hi")');
        if (javaScriptEnabled) expect(await page.evaluate(() => (window as any).publicDocument === document)).toBe(true);
        await signIn.click();
        await expect(page).toHaveURL(/\/-\/login$/);
        await expect(page.getByRole('heading', { name: 'Sign in', exact: true })).toBeVisible();
        expect((await page.goto(baseURL + '/alice/demo'))?.status()).toBe(404);
        expect(errors).toEqual([]);
      } finally {
        await context.close();
      }
    });
  }
}
