import { expect, test } from '@playwright/test';

// Connected functional diagnostic. Not an approved zero-pixel walkthrough.
test('Administrator publishes the real schedule used by local alert actions', async ({ page }, info) => {
  const name = process.env.MEDINAG_E2E_MEDICATION_NAME;
  const time = process.env.MEDINAG_E2E_SCHEDULED_TIME;
  if (!name || !time) throw new Error('Run through the isolated connected runner.');
  await page.goto('/#/schedules', { waitUntil: 'domcontentloaded' });
  await expect(page.getByText('No doses in this plan yet')).toBeVisible();
  await page.getByRole('link', { name: 'Settings' }).click();
  await page.getByLabel('Snooze interval').selectOption('15');
  await page.getByLabel('Repeat interval').selectOption('1');
  await expect(page.getByTestId('coverage-warning')).toContainText('62');
  await expect(page.getByTestId('coverage-warning')).toContainText('60');
  await page.getByLabel('Repeat interval').selectOption('10');
  await expect(page.getByTestId('coverage-warning')).toHaveCount(0);
  await expect(page.getByTestId('coverage-summary')).toContainText('8 of 60');
  await page.getByRole('button', { name: 'Save changes' }).click();
  await expect(page.getByRole('status')).toHaveText('Settings saved.');
  await page.getByRole('link', { name: 'Schedule', exact: true }).click();
  await page.getByRole('button', { name: 'Add dose' }).click();
  await page.getByLabel('Medication label').fill(name);
  await page.getByLabel('Dose time').fill(time);
  await page.getByRole('button', { name: 'Save dose' }).click();
  await expect(page.getByRole('status')).toHaveText('Dose added.');
  await page.getByRole('button', { name: 'Publish schedule' }).click();
  await expect(page.getByRole('status')).toHaveText('Schedule published.');
  await info.attach('published-real-schedule', { body: await page.screenshot(), contentType: 'image/png' });
});
