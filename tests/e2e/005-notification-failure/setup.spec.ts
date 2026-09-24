import { expect, test } from '@playwright/test';
import { TestStepHelper } from '../helpers/test-step-helper';

test.setTimeout(20_000);

test('US-005: Lori configures an alerting medication plan', async ({ page }, testInfo) => {
  const medicationName = process.env.MEDINAG_E2E_MEDICATION_NAME;
  const scheduledTime = process.env.MEDINAG_E2E_SCHEDULED_TIME;
  const smsNumber = process.env.MEDINAG_E2E_SMS_NUMBER;
  if (!medicationName || !scheduledTime || !smsNumber) {
    throw new Error('The connected failure environment is incomplete.');
  }
  const tester = new TestStepHelper(page, testInfo, 'web');

  await page.goto('/#/schedules', { waitUntil: 'domcontentloaded' });
  await page.getByRole('button', { name: 'Add dose' }).click();
  await page.getByLabel('Medication label').fill(medicationName);
  await page.getByLabel('Dose time').fill(scheduledTime);
  await page.getByRole('button', { name: 'Save dose' }).click();
  await expect(page.getByRole('status')).toHaveText('Dose added.');

  await page.getByRole('link', { name: 'Settings' }).click();
  await page.getByLabel('SMS number').fill(smsNumber);
  await page.getByRole('button', { name: 'Save changes' }).click();
  await expect(page.getByRole('status')).toHaveText('Settings saved.');
  await expect(page.getByLabel('SMS number')).toHaveValue(smsNumber);

  await page.getByRole('link', { name: 'Schedule' }).click();
  await page.getByRole('button', { name: 'Publish schedule' }).click();
  await tester.step('alerting-plan-published', {
    description: 'Lori publishes a schedule with an SMS alert destination',
    verifications: [
      {
        claim: 'failure.plan-published',
        check: async () =>
          await expect(page.getByText('Published', { exact: true })).toBeVisible()
      },
      {
        claim: 'failure.sms-configured',
        check: async () => {
          await page.getByRole('link', { name: 'Settings' }).click();
          await expect(page.getByLabel('SMS number')).toHaveValue(smsNumber);
          await page.getByRole('link', { name: 'Schedule' }).click();
        }
      }
    ]
  });
});
