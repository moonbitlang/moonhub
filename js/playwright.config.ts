import { defineConfig } from '@playwright/test';

const externalURL = process.env.MOONHUB_TEST_URL;
const fixtureURL = `http://127.0.0.1:${process.env.MOONHUB_BROWSER_PORT ?? '18092'}`;

export default defineConfig({
  testDir: './tests',
  workers: 1,
  timeout: 30000,
  webServer: externalURL ? undefined : {
    command: 'node scripts/browser-server.mjs',
    wait: { stdout: /MoonHub browser fixture ready/ },
    timeout: 120000,
  },
  use: {
    baseURL: externalURL ?? fixtureURL,
    headless: true,
    launchOptions: { executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH },
  },
});
