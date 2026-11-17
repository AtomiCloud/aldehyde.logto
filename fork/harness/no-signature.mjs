// Browser probe for the aldehyde fork's page-only "Powered by Logto" patch.
//
// Drives a real headless Chrome against a running Logto image:
//   1. the sign-in page reached through a real OIDC authorization request;
//   2. the account center page after a real username + password sign-in.
// On each page it first proves the page really rendered (positive control), then
// looks for every trace of the upstream signature:
//   - any `[data-logto-signature]` / `[data-logto-signature-container]` element,
//   - any `.logto_signature` element (the stable custom-CSS hook),
//   - the injected `style[data-logto-signature-guard]` element,
//   - "Powered by" in the rendered text or in any aria-label.
//
// Prints one JSON report on stdout. Exit codes:
//   0  both pages rendered and neither shows any signature trace
//   3  both pages rendered and at least one shows a signature trace
//   2  a page did not render (the probe proves nothing; treat as broken)
import { createHash, randomBytes } from 'node:crypto';
import { createRequire } from 'node:module';
import { setTimeout as delay } from 'node:timers/promises';

const require = createRequire(new URL('../../packages/integration-tests/package.json', import.meta.url));
const puppeteer = require('puppeteer');

const env = (name) => {
  const value = process.env[name];
  if (!value) {
    console.error(`missing env ${name}`);
    process.exit(2);
  }
  return value;
};

const endpoint = env('PROBE_ENDPOINT');
const clientId = env('PROBE_CLIENT_ID');
const redirectUri = env('PROBE_REDIRECT_URI');
const username = env('PROBE_USERNAME');
const password = env('PROBE_PASSWORD');
// Time the page keeps running after the control appears, so a signature that a
// late effect would add (or re-add) is still caught.
const settleMs = Number(process.env.PROBE_SETTLE_MS ?? '3000');

const inspect = async (page) =>
  page.evaluate(() => {
    const text = document.body?.innerText ?? '';
    const ariaLabels = [...document.querySelectorAll('[aria-label]')]
      .map((element) => element.getAttribute('aria-label') ?? '')
      .filter((label) => /powered\s*by/i.test(label));
    return {
      url: location.href,
      dataSignature: document.querySelectorAll(
        '[data-logto-signature], [data-logto-signature-container]'
      ).length,
      cssHook: document.querySelectorAll('.logto_signature').length,
      guardStyle: document.querySelectorAll('style[data-logto-signature-guard]').length,
      poweredByText: /powered\s*by/i.test(text),
      poweredByAria: ariaLabels.length,
    };
  });

const hasSignature = (report) =>
  report.dataSignature > 0 ||
  report.cssHook > 0 ||
  report.guardStyle > 0 ||
  report.poweredByText ||
  report.poweredByAria > 0;

const report = { signIn: null, account: null, errors: [] };

const browser = await puppeteer.launch({
  headless: true,
  executablePath: process.env.CHROME_PATH || undefined,
  args: ['--no-sandbox', '--disable-dev-shm-usage'],
});

try {
  const page = await browser.newPage();
  page.setDefaultTimeout(30_000);

  // 1. Sign-in page through a real authorization request.
  // SPA clients must use PKCE; the probe never redeems the code, so the verifier is discarded.
  const codeChallenge = createHash('sha256')
    .update(randomBytes(32).toString('base64url'))
    .digest('base64url');
  const authUrl = new URL('/oidc/auth', endpoint);
  authUrl.search = new URLSearchParams({
    client_id: clientId,
    redirect_uri: redirectUri,
    response_type: 'code',
    scope: 'openid profile',
    state: 'aldehyde-no-signature',
    prompt: 'login',
    code_challenge: codeChallenge,
    code_challenge_method: 'S256',
  }).toString();
  await page.goto(authUrl.href, { waitUntil: 'networkidle0' });
  try {
    await page.waitForSelector('input[name="identifier"]', { visible: true });
    await delay(settleMs);
    report.signIn = { rendered: true, ...(await inspect(page)) };
  } catch (error) {
    report.signIn = { rendered: false, url: page.url() };
    report.errors.push(`sign-in page did not render: ${String(error)}`);
  }

  // 2. Sign in with the probe user (identifier first, password on the same or the next page).
  if (report.signIn?.rendered) {
    await page.type('input[name="identifier"]', username);
    const passwordOnSamePage = await page.$('input[name="password"]');
    if (passwordOnSamePage) {
      await page.type('input[name="password"]', password);
    }
    await page.click('button[type="submit"]');
    if (!passwordOnSamePage) {
      await page.waitForSelector('input[name="password"]', { visible: true });
      await page.type('input[name="password"]', password);
      await page.click('button[type="submit"]');
    }
    await page.waitForRequest((request) => request.url().startsWith(redirectUri), {
      timeout: 30_000,
    });
  }

  // 3. Account center with the live Logto session.
  if (report.signIn?.rendered) {
    await page.goto(new URL('/account', endpoint).href, { waitUntil: 'networkidle0' });
    try {
      await page.waitForFunction(
        (expected) => document.body?.innerText.includes(expected),
        { timeout: 30_000 },
        username
      );
      await delay(settleMs);
      report.account = { rendered: true, ...(await inspect(page)) };
    } catch (error) {
      report.account = { rendered: false, url: page.url() };
      report.errors.push(`account page did not render the signed-in user: ${String(error)}`);
    }
  }
} catch (error) {
  report.errors.push(String(error));
} finally {
  await browser.close();
}

const rendered = Boolean(report.signIn?.rendered && report.account?.rendered);
report.signIn &&= { ...report.signIn, signature: report.signIn.rendered && hasSignature(report.signIn) };
report.account &&= {
  ...report.account,
  signature: report.account.rendered && hasSignature(report.account),
};
console.log(JSON.stringify(report, null, 2));

if (!rendered) {
  process.exit(2);
}
process.exit(report.signIn.signature || report.account.signature ? 3 : 0);
