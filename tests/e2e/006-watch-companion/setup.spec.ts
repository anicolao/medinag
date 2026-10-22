import { expect, test } from '@playwright/test';
import { TestStepHelper } from '../helpers/test-step-helper';

test('US-006: publish a real medication plan', async ({ page }, testInfo) => {
  const tester = new TestStepHelper(page, testInfo, 'web');
  await page.goto('/#/schedules', { waitUntil: 'domcontentloaded' });
  await expect(page.locator('html')).toHaveAttribute('data-app-ready', 'true');
  await tester.step('watch-empty-dashboard', {
    description: 'The administrator opens an empty Firebase-connected plan',
    verifications: [{ claim: 'watch.web.empty', check: async () =>
      await expect(page.getByText('No doses in this plan yet')).toBeVisible() }]
  });
  const name = process.env.MEDINAG_E2E_MEDICATION_NAME;
  const time = process.env.MEDINAG_E2E_SCHEDULED_TIME;
  if (!name || !time) throw new Error('Connected environment is required.');
  await page.getByRole('button', { name: 'Add dose' }).click();
  await page.getByLabel('Medication label').fill(name);
  await page.getByLabel('Dose time').fill(time);
  await page.getByRole('button', { name: 'Save dose' }).click();
  await expect(page.getByRole('status')).toHaveText('Dose added.');
  await page.getByRole('button', { name: 'Publish schedule' }).click();
  await tester.step('watch-published-plan', {
    description: 'The administrator publishes the medication dose for the paired devices',
    verifications: [{ claim: 'watch.web.published', check: async () =>
      await expect(page.getByRole('status')).toHaveText('Schedule published.') }]
  });
});
