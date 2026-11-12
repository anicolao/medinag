import { expect, test } from '@playwright/test';

test('The real in-app completion returns to the administrator', async ({ page }, info) => {
  const name = process.env.MEDINAG_E2E_MEDICATION_NAME;
  if (!name) throw new Error('Connected environment is required.');
  await page.goto('/#/today', { waitUntil: 'domcontentloaded' });
  await expect(page.getByTestId('today-event-list')).toContainText(name);
  await expect(page.getByTestId('today-event-list')).toContainText('Completed');
  await info.attach('real-completion-received', { body: await page.screenshot(), contentType: 'image/png' });
});
