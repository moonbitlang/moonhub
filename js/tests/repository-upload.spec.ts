import { test, expect } from '@playwright/test';

test('pending uploads block navigation and submission; failed uploads preserve input and retry', async ({ page }) => {
  await page.goto('/-/login');
  await expect(page.locator('html')).toHaveAttribute('data-hydrated', 'true');
  await page.locator('[name=name_key]').fill('alice');
  await page.locator('[name=password]').fill('browser-test-password');
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  await expect(page).toHaveURL(/\/$/);
  await page.goto('/alice/demo/issues/new');
  await page.locator('[name=title]').fill('Retained upload input');
  const body = page.locator('textarea[name=description]');
  await body.evaluate(element => element.dispatchEvent(new Event('markdown-focus', { cancelable: true })));
  await expect(body).toHaveAttribute('data-markdown-source', 'easymde');
  await body.evaluate(element => (element.closest('.markdown-editor')!.querySelector('.CodeMirror') as any).CodeMirror.setValue('Keep this description.'));
  let release!: () => void;
  const gate = new Promise<void>(resolve => { release = resolve; });
  await page.route('**/attachments?*', async route => {
    await gate;
    await route.fulfill({ status: 500, contentType: 'application/json', json: { error: { message: 'Fixture upload failure' } } });
  });
  let mutations = 0;
  page.on('request', request => { if (request.method() === 'POST' && new URL(request.url()).pathname === '/alice/demo/issues') mutations++; });
  const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jWZkAAAAASUVORK5CYII=', 'base64');
  try {
    await page.locator('.markdown-editor input[type=file]').setInputFiles({ name: 'fixture.png', mimeType: 'image/png', buffer: png });
    await expect(body).toHaveAttribute('data-image-upload-pending', 'true');
    await page.locator('.repository-tabs').getByRole('link', { name: 'Code', exact: true }).click();
    await expect(page).toHaveURL(/issues\/new$/);
    await page.getByRole('button', { name: 'Create issue', exact: true }).click();
    expect(mutations).toBe(0);
  } finally { release(); }
  await expect(page.locator('.markdown-editor-status')).toContainText('Fixture upload failure');
  await expect(page.locator('[name=title]')).toHaveValue('Retained upload input');
  await expect(body).toHaveValue('Keep this description.');
  await expect(page.locator('.mr-form')).not.toHaveAttribute('aria-busy', 'true');
  await page.unroute('**/attachments?*');
  await page.getByRole('button', { name: 'Retry upload', exact: true }).click();
  await expect(body).toHaveValue(/\/alice\/demo\/attachments\//);
  expect(await body.inputValue()).toContain('Keep this description.');
  await expect(body).not.toHaveAttribute('data-image-upload-pending', 'true');
});
