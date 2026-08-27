import { expect, test } from '@playwright/test';
import { TestStepHelper } from '../helpers/test-step-helper';

test('US-002: Lori manages medication schedules', async ({ page }, testInfo) => {
  const tester = new TestStepHelper(page, testInfo);
  tester.setMetadata(
    'Manage medication schedules',
    "As Lori, I want to create, edit, and pause Steve's medication schedules so that his reminders match the daily plan."
  );

  await page.goto('/#/schedules');

  await tester.step('empty-schedule-list', {
    description: 'Lori starts with a clear medication schedule',
    verifications: [
      {
        spec: 'The schedule page reports deterministic rendering is ready',
        check: async () =>
          await expect(page.locator('html')).toHaveAttribute('data-app-ready', 'true')
      },
      {
        spec: 'The medication schedule heading is visible',
        check: async () =>
          await expect(
            page.getByRole('heading', { level: 1, name: 'Medication schedules' })
          ).toBeVisible()
      },
      {
        spec: 'No schedules are present',
        check: async () =>
          await expect(page.getByText('No medication schedules yet')).toBeVisible()
      },
      {
        spec: 'The dashboard is connected to the isolated Firebase environment',
        check: async () =>
          await expect(page.getByText('Google account linked · Firebase synced')).toBeVisible()
      }
    ]
  });

  await page.getByRole('button', { name: 'Add schedule' }).click();

  await tester.step('add-schedule-form', {
    description: 'Lori opens the new schedule form',
    verifications: [
      {
        spec: 'The schedule dialog is visible',
        check: async () =>
          await expect(page.getByRole('dialog', { name: 'Add schedule' })).toBeVisible()
      },
      {
        spec: 'Every day is selected by default',
        check: async () =>
          await expect(page.locator('input[name="daysOfWeek"]:checked')).toHaveCount(7)
      }
    ]
  });

  await page.getByLabel('Medication label').fill('Morning Prescription Doses');
  await page.getByLabel('Dose time').fill('08:00');
  await page.getByRole('button', { name: 'Save schedule' }).click();

  await tester.step('schedule-created', {
    description: 'Lori adds Steve’s morning medication schedule',
    verifications: [
      {
        spec: 'The morning medication label is listed',
        check: async () =>
          await expect(page.getByRole('heading', { name: 'Morning Prescription Doses' }))
            .toBeVisible()
      },
      {
        spec: 'The schedule repeats every day at 8:00 AM',
        check: async () =>
          await expect(page.getByTestId('schedule-list')).toContainText(
            /8:00 AM\s+Every day/
          )
      },
      {
        spec: 'The schedule is active',
        check: async () =>
          await expect(page.getByTestId('schedule-list')).toContainText('Active')
      }
    ]
  });

  await page.getByRole('link', { name: 'Today' }).click();
  await tester.step('medication-event-created', {
    description: 'The schedule produces a pending medication event in Firestore',
    verifications: [
      {
        spec: 'The Today route receives the medication event through a Firestore listener',
        check: async () =>
          await expect(page.getByTestId('today-event-list')).toContainText(
            'Morning Prescription Doses'
          )
      },
      {
        spec: 'The event is pending for Steve',
        check: async () =>
          await expect(page.getByTestId('today-event-list')).toContainText('Pending')
      }
    ]
  });
  await page.getByRole('link', { name: 'Schedules' }).click();

  await page.getByRole('button', { name: 'Edit Morning Prescription Doses' }).click();
  await page.getByLabel('Medication label').fill('Morning Meds — 2 pills');
  await page.getByLabel('Dose time').fill('08:15');
  await page.getByRole('button', { name: 'Save schedule' }).click();

  await tester.step('schedule-edited', {
    description: 'Lori updates the medication label and dose time',
    verifications: [
      {
        spec: 'The updated medication label is listed',
        check: async () =>
          await expect(page.getByRole('heading', { name: 'Morning Meds — 2 pills' }))
            .toBeVisible()
      },
      {
        spec: 'The updated schedule time is 8:15 AM',
        check: async () =>
          await expect(page.getByTestId('schedule-list')).toContainText('8:15 AM')
      },
      {
        spec: 'The dashboard confirms the update',
        check: async () =>
          await expect(page.getByRole('status')).toHaveText('Schedule updated.')
      }
    ]
  });

  await page.getByRole('button', { name: 'Pause Morning Meds — 2 pills' }).click();

  await tester.step('schedule-paused', {
    description: 'Lori pauses the medication schedule',
    verifications: [
      {
        spec: 'The schedule is marked paused',
        check: async () =>
          await expect(page.getByTestId('schedule-list')).toContainText('Paused')
      },
      {
        spec: 'The dashboard confirms that the schedule is paused',
        check: async () =>
          await expect(page.getByRole('status')).toHaveText('Schedule paused.')
      },
      {
        spec: 'The schedule can be resumed',
        check: async () =>
          await expect(
            page.getByRole('button', { name: 'Resume Morning Meds — 2 pills' })
          ).toBeVisible()
      }
    ]
  });

  tester.generateDocs();
});
