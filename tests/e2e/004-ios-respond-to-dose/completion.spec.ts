import { expect, test } from '@playwright/test';

test.setTimeout(10_000);

test('US-004 completion returns to the administrator dashboard', async ({ page }) => {
  const medicationName = process.env.MEDINAG_E2E_MEDICATION_NAME;
  if (!medicationName) {
    throw new Error('MEDINAG_E2E_MEDICATION_NAME must be supplied.');
  }

  await page.goto('/#/today', { waitUntil: 'domcontentloaded' });

  const events = page.getByTestId('today-event-list');
  await expect(events).toContainText(medicationName);
  await expect(events).toContainText('Completed');

  const coverage = page.getByTestId('device-coverage');
  await expect(coverage).toContainText('Ready');
  await expect(coverage).toContainText('reminders confirmed by iOS');
  await expect(page.getByTestId('system-incidents')).toHaveText(
    'No open reminder-system incidents.'
  );

  await expect(page).toHaveScreenshot(
    ['web', '002-completion-returned-to-dashboard.png'],
    {
      animations: 'disabled',
      caret: 'hide',
      maxDiffPixelRatio: 0,
      maxDiffPixels: 0,
      scale: 'css',
      threshold: 0,
      timeout: 2_000
    }
  );
});
