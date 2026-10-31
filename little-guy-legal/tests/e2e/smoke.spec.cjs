// Browser end-to-end smoke test with Playwright (preinstalled Chromium). Run:
//   node tests/e2e/smoke.spec.cjs            (expects the app on http://127.0.0.1:8767 with the scripted provider)
// or: bash tests/e2e/run.sh                   (starts a throwaway server, runs this, stops it)
const { chromium } = require('playwright');
const path = require('path');

const BASE = process.env.LGL_E2E_BASE || 'http://127.0.0.1:8767';
const FIX = path.resolve(__dirname, '../../fixtures/synthetic/files');

function assert(cond, msg) { if (!cond) { throw new Error('ASSERTION FAILED: ' + msg); } }

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
  const errors = [];
  page.on('pageerror', (e) => errors.push(String(e)));
  page.on('dialog', (d) => d.accept()); // the review form asks for confirmation before recording an action
  page.on('console', (m) => { if (m.type() === 'error' && !/40[0-9]/.test(m.text())) errors.push(m.text()); });

  await page.goto(BASE + '/');
  assert(await page.getByText('Little Guy Legal').first().isVisible(), 'brand visible');
  assert(await page.getByText(/attorney review/i).first().isVisible(), 'attorney-review label visible');
  const banner = await page.getByText(/TEST PROVIDER/i).first().isVisible().catch(() => false);
  assert(banner, 'scripted provider banner must be visible when the test provider is active');

  // New case
  await page.goto(BASE + '/cases/new');
  await page.getByLabel(/title/i).fill('E2E Synthetic Lockout Case');
  await page.getByRole('button', { name: /create/i }).click();
  await page.waitForURL(/\/cases\/case_/);
  const caseUrl = page.url();

  // Upload documents via the file input
  const input = page.locator('input[type=file]');
  await input.setInputFiles([path.join(FIX, '01_commercial_lease.pdf'), path.join(FIX, '02_notice_of_default.docx'), path.join(FIX, '03_email_chain.docx')]);
  await page.getByText('D3').first().waitFor({ timeout: 30000 });
  assert(await page.getByText(/extracted/i).first().isVisible(), 'extraction status shown');

  // Intake
  await page.getByLabel(/tenant/i).check();
  await page.getByLabel(/what happened/i).fill('Locked out after withholding rent for an HVAC repair.');
  await page.getByLabel(/outcome/i).fill('Regain possession.');
  const save = page.getByRole('button', { name: /save/i }).first();
  if (await save.isVisible().catch(() => false)) await save.click();

  // Start analysis
  await page.getByRole('button', { name: /start analysis/i }).click();
  await page.waitForURL(/progress/);
  await page.getByText(/Draft report/i).first().waitFor();
  await page.getByText(/completed/i).first().waitFor({ timeout: 60000 });
  await page.waitForFunction(() => document.body.innerText.toLowerCase().includes('open review'), null, { timeout: 60000 });
  assert(!/\d+%/.test(await page.locator('main').innerText()), 'no invented progress percentages');

  // Review + evidence drawer
  await page.goto(caseUrl + '/review');
  await page.getByText(/executive summary/i).first().waitFor({ timeout: 20000 });
  await page.getByRole('tab', { name: /Key facts/i }).click();
  const chip = page.locator('button.chip-ref', { hasText: 'D1:p1' }).first();
  await chip.waitFor({ timeout: 20000 });
  await chip.click();
  await page.getByText(/RETAIL LEASE AGREEMENT/i).first().waitFor({ timeout: 10000 });
  await page.keyboard.press('Escape');

  // Report: draft status, approval requires reviewer
  await page.goto(caseUrl + '/report');
  await page.getByText(/DRAFT/i).first().waitFor({ timeout: 20000 });
  const draftText = await page.locator('main').innerText();
  assert(/NOT APPROVED/.test(draftText) && !/Reviewed by/.test(draftText), 'draft not shown as approved');
  await page.getByLabel(/reviewer/i).fill('E2E Operator');
  await page.getByRole('button', { name: /^approve/i }).click();
  await page.waitForFunction(() => /approved/i.test(document.body.innerText) && /E2E Operator/.test(document.body.innerText), null, { timeout: 30000 });

  await browser.close();
  if (errors.length) { console.error('Console/page errors:', errors); process.exit(1); }
  console.log('E2E smoke passed');
})().catch((e) => { console.error(e); process.exit(1); });
