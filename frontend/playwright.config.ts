import { defineConfig } from '@playwright/test';
import fs from 'node:fs';
import path from 'node:path';

const frontendRoot = __dirname;
const repositoryRoot = path.resolve(frontendRoot, '..');
const backendRoot = path.join(repositoryRoot, 'backend');
const backendPython = process.env.FINGUARD_BACKEND_PYTHON ?? (
  process.platform === 'win32'
    ? path.join(backendRoot, '.venv', 'Scripts', 'python.exe')
    : 'python3'
);
const backendPort = 8000;
const webPort = 8080;
const backendUrl = `http://127.0.0.1:${backendPort}`;
const webUrl = `http://127.0.0.1:${webPort}`;
const browserChannel = process.env.FINGUARD_PLAYWRIGHT_CHANNEL ?? (
  process.env.CI ? undefined : 'chrome'
);
fs.mkdirSync(path.join(repositoryRoot, 'tmp'), { recursive: true });

export default defineConfig({
  testDir: './e2e',
  outputDir: path.join(repositoryRoot, 'tmp', 'playwright-test-results'),
  fullyParallel: false,
  forbidOnly: Boolean(process.env.CI),
  retries: process.env.CI ? 1 : 0,
  reporter: 'line',
  timeout: 45_000,
  expect: { timeout: 10_000 },
  use: {
    baseURL: webUrl,
    viewport: { width: 1440, height: 900 },
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
    video: 'off',
    serviceWorkers: 'block',
    // Local runs use the installed Chrome channel, so QA does not depend on a
    // potentially stale Playwright browser cache. CI keeps Playwright's bundled
    // Chromium unless the runner deliberately selects another channel.
    channel: browserChannel,
  },
  webServer: [
    {
      command: `"${backendPython}" -m uvicorn app.main:app --host 127.0.0.1 --port ${backendPort}`,
      cwd: backendRoot,
      env: {
        APP_ENV: 'development',
        DATABASE_URL: `sqlite:///${path.join(repositoryRoot, 'tmp', `playwright-${process.pid}.db`).replaceAll('\\', '/')}`,
        ALLOWED_ORIGINS: webUrl,
        AUTH_SECRET_KEY: 'playwright-only-auth-secret-key-32-characters',
        ENABLE_AI_CONTEXT: 'false',
        GEMINI_API_KEY: '',
      },
      url: `${backendUrl}/api/v1/health`,
      reuseExistingServer: false,
      timeout: 30_000,
    },
    {
      command: `"${backendPython}" -m http.server ${webPort} --bind 127.0.0.1 --directory build/web`,
      cwd: frontendRoot,
      url: webUrl,
      reuseExistingServer: false,
      timeout: 30_000,
    },
  ],
});
