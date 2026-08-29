import { expect, Page, test } from '@playwright/test';
import path from 'node:path';

const visualQaRoot = path.resolve(__dirname, '..', '..', 'tmp', 'visual-qa');

type Diagnostics = {
  console: string[];
  pageErrors: string[];
  requestFailures: string[];
};

const benignChromiumDriverWarning =
  /^\[warning\] \[\.WebGL-0x[0-9a-f]+\]GL Driver Message \(OpenGL, Performance, GL_CLOSE_PATH_NV, High\): GPU stall due to ReadPixels(?: \(this message will no longer repeat\))?$/;

function isBenignChromiumDriverWarning(message: string): boolean {
  return benignChromiumDriverWarning.test(message);
}

function observe(page: Page): Diagnostics {
  const diagnostics: Diagnostics = { console: [], pageErrors: [], requestFailures: [] };
  page.on('console', (message) => {
    if (message.type() === 'warning' || message.type() === 'error') {
      diagnostics.console.push(`[${message.type()}] ${message.text()}`);
    }
  });
  page.on('pageerror', (error) => diagnostics.pageErrors.push(error.message));
  page.on('requestfailed', (request) => {
    diagnostics.requestFailures.push(
      `${request.method()} ${request.url()} ${request.failure()?.errorText ?? ''}`,
    );
  });
  return diagnostics;
}

async function enableAccessibility(page: Page): Promise<void> {
  const placeholder = page.locator(
    'flt-semantics-placeholder[aria-label="Enable accessibility"]',
  );
  await placeholder.waitFor({ state: 'attached' });
  // Flutter intentionally keeps this framework opt-in outside the viewport.
  // Dispatch the framework's activation event directly; every product
  // interaction after bootstrap still uses actionability-checked locators.
  await placeholder.evaluate((element) => (element as HTMLElement).click());
  await expect(placeholder).toHaveCount(0);
}

async function openAsGuest(page: Page): Promise<void> {
  await page.goto('/');
  await enableAccessibility(page);
  await expect(page.getByRole('group', { name: /^Start with FinGuard/ })).toBeVisible();
  await page.getByRole('button', { name: 'Continue privately without an account' }).click();
  await expect(page.getByText('Try with demo data')).toBeVisible();
}

async function openPaste(page: Page): Promise<void> {
  await page.getByRole('button', { name: 'Paste UPI Link' }).click();
  await expect(page.getByText('Review before handoff')).toBeVisible();
}

function expectClean(
  diagnostics: Diagnostics,
  options: { allowConsole?: RegExp; allowRequestFailures?: RegExp } = {},
): void {
  const unexpectedConsole = diagnostics.console.filter(
    (message) =>
      !isBenignChromiumDriverWarning(message) &&
      !(options.allowConsole?.test(message) ?? false),
  );
  const unexpectedFailures = options.allowRequestFailures
    ? diagnostics.requestFailures.filter(
        (failure) => !options.allowRequestFailures!.test(failure),
      )
    : diagnostics.requestFailures;
  expect(unexpectedConsole).toEqual([]);
  expect(diagnostics.pageErrors).toEqual([]);
  expect(unexpectedFailures).toEqual([]);
}

test('browser diagnostics ignore only the known Chromium ReadPixels driver warning', () => {
  const exactWarning =
    '[warning] [.WebGL-0x36340016ae00]GL Driver Message (OpenGL, Performance, GL_CLOSE_PATH_NV, High): GPU stall due to ReadPixels';

  expect(isBenignChromiumDriverWarning(exactWarning)).toBe(true);
  expect(
    isBenignChromiumDriverWarning(`${exactWarning} (this message will no longer repeat)`),
  ).toBe(true);
  expect(isBenignChromiumDriverWarning(exactWarning.replace('[warning]', '[error]'))).toBe(false);
  expect(isBenignChromiumDriverWarning(exactWarning.replace('ReadPixels', 'app warning'))).toBe(
    false,
  );
});

const riskCases = [
  {
    name: 'safe',
    level: 'SAFE',
    uri: 'upi://pay?pa=live.coffee%40okaxis&pn=Live%20Coffee&am=180&cu=INR',
    action: 'Continue to UPI app',
    confirmation: 'Open this request in a UPI app?',
    requiresVerification: false,
  },
  {
    name: 'caution',
    level: 'CAUTION',
    uri: 'upi://pay?pa=live.market%40okaxis&pn=Live%20Market&am=4500&cu=INR',
    action: 'Continue anyway',
    confirmation: 'Continue with caution?',
    requiresVerification: true,
  },
  {
    name: 'high',
    level: 'HIGH RISK',
    uri: 'upi://pay?pa=secure-kyc-update%40okaxis&pn=KYC%20Support&am=25000&cu=INR&tn=Urgent%20KYC%20account%20block',
    action: 'Continue anyway',
    confirmation: 'Continue despite high risk?',
    requiresVerification: true,
  },
] as const;

for (const riskCase of riskCases) {
  test(`${riskCase.name} live assessment remains behind cancelled handoff`, async ({ page }) => {
    // A high-risk result sits behind a trust-scaled cool-off of up to twenty
    // seconds, which does not fit the default budget alongside page start-up.
    test.setTimeout(riskCase.level === 'HIGH RISK' ? 120_000 : 45_000);
    const diagnostics = observe(page);
    await openAsGuest(page);
    await openPaste(page);
    await page.getByLabel('UPI payment link').fill(riskCase.uri);
    await page.getByRole('button', { name: 'Analyze payment' }).click();
    await expect(
      page.getByRole('heading', { name: new RegExp(`^Risk level ${riskCase.level}\\b`) }),
    ).toBeVisible();
    await expect(page.getByText('Why do we say this?')).toBeVisible();
    await page.screenshot({
      path: path.join(visualQaRoot, `${riskCase.name}-risk-1440.png`),
      fullPage: true,
    });

    const handoff = page.getByRole('button', { name: riskCase.action });
    if (riskCase.requiresVerification) {
      await expect(handoff).toBeDisabled();
      // click(), not check(): Flutter rebuilds the semantics node when the
      // box toggles, so check() re-reads aria-checked on an element that no
      // longer exists and reports no state change even though the box ticked.
      // The counter below is the real assertion that all three registered.
      await page.getByRole('checkbox', {
        name: 'I checked the recipient VPA using a source I trust.',
      }).click();
      await page.getByRole('checkbox', {
        name: 'I reviewed the amount and currency.',
      }).click();
      await page.getByRole('checkbox', {
        name: /I ignored urgency and contact instructions/,
      }).click();
      await expect(page.getByText('Verification complete').first()).toBeVisible();
      if (riskCase.level === 'HIGH RISK') {
        await expect(page.getByText(/this pause is deliberate/i)).toBeVisible();
        await expect(handoff).toBeDisabled();
        // The pause is scaled by payee trust, and this fixture grades D, which
        // earns the longest one. The wait has to outlast it by a clear margin.
        await expect(handoff).toBeEnabled({ timeout: 40_000 });
      } else {
        await expect(handoff).toBeEnabled();
      }
    }
    await handoff.click();
    await expect(page.getByText(riskCase.confirmation)).toBeVisible();
    await page.getByRole('button', { name: 'Cancel' }).click();
    await expect(page.getByText(riskCase.confirmation)).toBeHidden();
    expectClean(diagnostics);
  });
}

test('guided offline Risk Lab compares outcomes responsively and stays view-only', async ({ page }) => {
  const diagnostics = observe(page);
  await openAsGuest(page);
  await page.getByRole('button', { name: 'Start 90-second demo' }).click();
  await expect(page.getByText('Compare policy evidence')).toBeVisible();
  await expect(page.getByText(/never call the API, AI or a UPI app/i)).toBeVisible();
  await expect(page.getByText('Case 1 of 4')).toBeVisible();
  await expect(page.getByRole('button', { name: 'Previous' })).toBeDisabled();

  const next = page.getByRole('button', { name: 'Next' });
  await next.click();
  await expect(page.getByText('Case 2 of 4')).toBeVisible();
  const teaStallEvidence = page.getByRole('group', {
    name: /Tea-stall sticker QR selected.*Payment amount is not specified/,
  });
  await teaStallEvidence.scrollIntoViewIfNeeded();
  await expect(teaStallEvidence).toBeVisible();
  await next.click();
  await expect(page.getByText('Case 3 of 4')).toBeVisible();
  await next.click();
  await expect(page.getByText('Case 4 of 4')).toBeVisible();
  await expect(next).toBeDisabled();
  const seededMatch = page.getByRole('group', {
    name: /Fake KYC request selected.*Recipient matches a seeded scam indicator/,
  });
  await seededMatch.scrollIntoViewIfNeeded();
  await expect(seededMatch).toBeVisible();
  await page.screenshot({
    path: path.join(visualQaRoot, 'risk-lab-1440.png'),
    fullPage: true,
  });

  await page.setViewportSize({ width: 375, height: 812 });
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - innerWidth);
  expect(overflow).toBeLessThanOrEqual(1);
  await page.screenshot({
    path: path.join(visualQaRoot, 'risk-lab-375.png'),
    fullPage: true,
  });

  await page.getByRole('button', { name: 'Open view-only result' }).click();
  await expect(
    page.getByRole('group', { name: /This result is view-only\. No UPI app can be opened from it\./ }),
  ).toBeVisible();
  await expect(page.getByRole('button', { name: /Continue.*UPI app/i })).toHaveCount(0);
  await expect(page.getByRole('button', { name: 'Prepare report' })).toHaveCount(0);
  await expect(page.getByRole('button', { name: 'Alert trusted contact' })).toHaveCount(0);
  await expect(page.getByRole('button', { name: 'I already paid' })).toHaveCount(0);
  expectClean(diagnostics);
});

test('demo and reopened history remain view-only', async ({ page }) => {
  const diagnostics = observe(page);
  await openAsGuest(page);
  await page.getByText('Fake KYC request').click();
  await expect(
    page.getByRole('heading', { name: /^Risk level HIGH RISK.*SEEDED DEMO DATA/ }),
  ).toBeVisible();
  await expect(
    page.getByRole('group', { name: /This result is view-only\. No UPI app can be opened from it\./ }),
  ).toBeVisible();
  await expect(page.getByRole('button', { name: /Continue.*UPI app/i })).toHaveCount(0);
  await expect(page.getByRole('button', { name: 'Prepare report' })).toHaveCount(0);
  await expect(page.getByRole('button', { name: 'Alert trusted contact' })).toHaveCount(0);
  await expect(page.getByRole('button', { name: 'I already paid' })).toHaveCount(0);
  await page.getByRole('button', { name: 'Close result' }).click();
  await page.getByRole('button', { name: 'Check history' }).click();
  await page.getByText('KYC Support').click();
  await expect(
    page.getByRole('group', { name: /This result is view-only\. No UPI app can be opened from it\./ }),
  ).toBeVisible();
  await expect(page.getByRole('button', { name: /Continue.*UPI app/i })).toHaveCount(0);
  await expect(page.getByRole('button', { name: 'Prepare report' })).toHaveCount(0);
  await expect(page.getByRole('button', { name: 'Alert trusted contact' })).toHaveCount(0);
  await expect(page.getByRole('button', { name: 'I already paid' })).toHaveCount(0);
  expectClean(diagnostics);
});

test('responsive home layouts fit 375, 768 and 1440 pixels', async ({ page }) => {
  const diagnostics = observe(page);
  await openAsGuest(page);
  for (const width of [375, 768, 1440]) {
    await page.setViewportSize({ width, height: width === 375 ? 812 : 900 });
    await expect(page.getByText('Know what you are paying.', { exact: true })).toBeVisible();
    const overflow = await page.evaluate(() => document.documentElement.scrollWidth - innerWidth);
    expect(overflow).toBeLessThanOrEqual(1);
    await page.screenshot({
      path: path.join(visualQaRoot, `home-${width}.png`),
      fullPage: true,
    });
  }
  expectClean(diagnostics);
});

test('empty history and malformed input have explicit states', async ({ page }) => {
  const diagnostics = observe(page);
  await openAsGuest(page);
  await page.getByRole('button', { name: 'Check history' }).click();
  await expect(page.getByText('No checks yet')).toBeVisible();
  await page.getByRole('button', { name: 'Back' }).click();
  await openPaste(page);
  await page.getByLabel('UPI payment link').fill('https://example.test/not-upi');
  await page.getByRole('button', { name: 'Analyze payment' }).click();
  await expect(page.getByRole('button', { name: 'Use reliable demo' })).toBeVisible();
  expectClean(diagnostics);
});

test('loading and server error states are visible and recoverable', async ({ page }) => {
  const diagnostics = observe(page);
  await openAsGuest(page);
  await openPaste(page);
  let releaseResponse!: () => void;
  const responseGate = new Promise<void>((resolve) => {
    releaseResponse = resolve;
  });
  await page.route('**/api/v1/payments/parse', async (route) => {
    await responseGate;
    await route.fulfill({
      status: 503,
      contentType: 'application/json',
      body: JSON.stringify({
        error: { code: 'TEST_UNAVAILABLE', message: 'Synthetic service unavailable.' },
      }),
    });
  });
  await page.getByLabel('UPI payment link').fill(
    'upi://pay?pa=server.error%40upi&pn=Server%20Error&am=10&cu=INR',
  );
  await page.getByRole('button', { name: 'Analyze payment' }).click();
  const loading = page.getByText('Checking request', { exact: true }).last();
  await expect(loading).toBeVisible();
  await expect(page.getByLabel('UPI payment link')).toBeDisabled();
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - innerWidth);
  expect(overflow).toBeLessThanOrEqual(1);
  await page.screenshot({
    path: path.join(visualQaRoot, 'loading-1440.png'),
  });
  releaseResponse();
  await expect(page.getByRole('group', { name: 'Synthetic service unavailable.' })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Try again' })).toBeVisible();
  expectClean(diagnostics, {
    allowConsole: /status of 503 \(Service Unavailable\)/,
  });
});

test('offline request failure is contained without opening a UPI app', async ({ page }) => {
  const diagnostics = observe(page);
  await openAsGuest(page);
  await openPaste(page);
  await page.route('**/api/v1/payments/parse', (route) => route.abort('internetdisconnected'));
  await page.getByLabel('UPI payment link').fill(
    'upi://pay?pa=offline.demo%40upi&pn=Offline%20Demo&am=10&cu=INR',
  );
  await page.getByRole('button', { name: 'Analyze payment' }).click();
  await expect(
    page.getByRole('group', {
      name: /cannot reach the safety service.*UPI app was not opened/i,
    }),
  ).toBeVisible();
  await expect(page.getByRole('button', { name: 'Use reliable demo' })).toBeVisible();
  expectClean(diagnostics, {
    allowConsole: /net::ERR_INTERNET_DISCONNECTED/,
    allowRequestFailures: /payments\/parse.*net::ERR_INTERNET_DISCONNECTED/,
  });
});

test('keyboard navigation exposes visible focus and activates account flow', async ({ page }) => {
  const diagnostics = observe(page);
  await page.goto('/');
  await enableAccessibility(page);
  const createAccount = page.getByRole('button', { name: 'Create account' });
  await expect(createAccount).toBeVisible();
  for (let attempt = 0; attempt < 8 && !(await createAccount.evaluate((element) => element === document.activeElement)); attempt += 1) {
    await page.keyboard.press('Tab');
  }
  await expect(createAccount).toBeFocused();
  await page.screenshot({
    path: path.join(visualQaRoot, 'keyboard-focus-1440.png'),
    fullPage: true,
  });
  await page.keyboard.press('Enter');
  await expect(page.getByRole('heading', { name: 'Create account' })).toBeVisible();
  expectClean(diagnostics);
});
