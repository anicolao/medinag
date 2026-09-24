import { expect, test } from '@playwright/test';
import { TestStepHelper } from '../helpers/test-step-helper';

// Browser fixture startup is part of Playwright's story timeout on a fresh
// hosted runner. Individual navigation, action, and assertion conditions remain
// capped at the required two seconds by playwright.config.ts.
test.setTimeout(20_000);

const required = (name: string): string => {
  const value = process.env[name];
  if (!value) {
    throw new Error(`${name} must be supplied by the connected E2E environment.`);
  }
  return value;
};

test('US-004: Lori schedules the dose Steve receives on iOS', async ({ page }, testInfo) => {
  const medicationName = required('MEDINAG_E2E_MEDICATION_NAME');
  const scheduledTime = required('MEDINAG_E2E_SCHEDULED_TIME');
  const tester = new TestStepHelper(page, testInfo, 'web');
  tester.setMetadata(
    'Lori schedules and Steve responds to a dose',
    'As Lori and Steve, we want a dashboard schedule to become an iOS notification and Steve’s response to return to the dashboard.'
  );

  await page.goto('/#/schedules', { waitUntil: 'domcontentloaded' });
  await tester.step('empty-connected-dashboard', {
    description: 'Lori opens a fresh dashboard connected to Firebase',
    verifications: [
      {
        claim: 'web.firebase-connected',
        check: async () =>
          await expect(page.getByText('Google signed in · Firebase synced')).toBeVisible()
      },
      {
        claim: 'web.no-preloaded-dose',
        check: async () =>
          await expect(page.getByText('No doses in this plan yet')).toBeVisible()
      }
    ]
  });

  await page.getByRole('button', { name: 'Add dose' }).click();
  await page.getByLabel('Medication label').fill(medicationName);
  await page.getByLabel('Dose time').fill(scheduledTime);
  await page.getByRole('button', { name: 'Save dose' }).click();
  await expect(page.getByRole('status')).toHaveText('Dose added.');
  await page.getByRole('button', { name: 'Publish schedule' }).click();

  await tester.step('schedule-written-to-firestore', {
    description: 'Lori saves and publishes the medication schedule through the dashboard',
    verifications: [
      {
        claim: 'web.saved-label',
        check: async () =>
          await expect(page.getByRole('heading', { name: medicationName })).toBeVisible()
      },
      {
        claim: 'web.repository-write',
        check: async () =>
          await expect(page.getByRole('status')).toHaveText('Schedule published.')
      },
      {
        claim: 'web.plan-published',
        check: async () =>
          await expect(page.getByText('Published', { exact: true })).toBeVisible()
      }
    ]
  });
});
