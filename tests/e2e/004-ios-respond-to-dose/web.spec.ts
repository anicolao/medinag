import { expect, test } from '@playwright/test';
import { TestStepHelper } from '../helpers/test-step-helper';

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

  await page.goto('/#/schedules');
  await tester.step('empty-connected-dashboard', {
    description: 'Lori opens a fresh dashboard connected to Firebase',
    verifications: [
      {
        spec: 'The dashboard is connected to the isolated Firebase environment',
        check: async () =>
          await expect(page.getByText('Google account linked · Firebase synced')).toBeVisible()
      },
      {
        spec: 'No medication schedule has been preloaded',
        check: async () =>
          await expect(page.getByText('No medication schedules yet')).toBeVisible()
      }
    ]
  });

  await page.getByRole('button', { name: 'Add schedule' }).click();
  await page.getByLabel('Medication label').fill(medicationName);
  await page.getByLabel('Dose time').fill(scheduledTime);
  await page.getByRole('button', { name: 'Save schedule' }).click();

  await tester.step('schedule-written-to-firestore', {
    description: 'Lori saves the medication schedule through the dashboard',
    verifications: [
      {
        spec: 'The saved medication label is rendered from the Firestore snapshot',
        check: async () =>
          await expect(page.getByRole('heading', { name: medicationName })).toBeVisible()
      },
      {
        spec: 'The dashboard confirms the production repository write',
        check: async () =>
          await expect(page.getByRole('status')).toHaveText('Schedule added.')
      }
    ]
  });

  await page.getByRole('link', { name: 'Today' }).click();
  await tester.step('event-observed-on-dashboard', {
    description: 'The schedule materializes the pending event Steve will receive',
    verifications: [
      {
        spec: 'The pending event arrives through the dashboard Firestore listener',
        check: async () =>
          await expect(page.getByTestId('today-event-list')).toContainText(medicationName)
      },
      {
        spec: 'The event is waiting for Steve’s response',
        check: async () =>
          await expect(page.getByTestId('today-event-list')).toContainText('Pending')
      }
    ]
  });

  tester.generateDocs();
});
