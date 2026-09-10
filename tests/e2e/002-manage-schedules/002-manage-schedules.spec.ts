import { expect, test } from '@playwright/test';
import { TestStepHelper } from '../helpers/test-step-helper';

test('US-002: an administrator publishes one medication plan', async ({ page }, testInfo) => {
  const tester = new TestStepHelper(page, testInfo);
  tester.setMetadata(
    'Publish one medication plan',
    'As an administrator, I want to publish one medication plan and its reminder defaults so that a patient can follow it.'
  );

  await page.goto('/#/schedules');
  await tester.step('empty-plan', {
    description: 'Lori opens her new administrator plan',
    verifications: [
      {
        spec: 'The authenticated administrator dashboard is ready',
        check: async () => expect(page.locator('html')).toHaveAttribute('data-app-ready', 'true')
      },
      {
        spec: 'The page manages one medication schedule',
        check: async () => expect(page.getByRole('heading', { level: 1, name: 'Your medication schedule' })).toBeVisible()
      },
      {
        spec: 'The unpublished plan starts empty',
        check: async () => expect(page.getByText('No doses in this plan yet')).toBeVisible()
      },
      {
        spec: 'The dashboard uses Google and Firebase',
        check: async () => expect(page.getByText('Google signed in · Firebase synced')).toBeVisible()
      }
    ]
  });

  await page.getByRole('button', { name: 'Add dose' }).click();
  await tester.step('add-dose-form', {
    description: 'Lori opens the first dose form',
    verifications: [
      {
        spec: 'The dose dialog is visible',
        check: async () => expect(page.getByRole('dialog', { name: 'Add dose' })).toBeVisible()
      },
      {
        spec: 'Every day is selected by default',
        check: async () => expect(page.locator('input[name="daysOfWeek"]:checked')).toHaveCount(7)
      }
    ]
  });

  await page.getByLabel('Medication label').fill('Morning Prescription Doses');
  await page.getByLabel('Dose time').fill('08:00');
  await page.getByRole('button', { name: 'Save dose' }).click();
  await tester.step('dose-created', {
    description: 'Lori adds the recurring morning dose',
    verifications: [
      {
        spec: 'The dose is rendered from Firestore',
        check: async () => expect(page.getByRole('heading', { name: 'Morning Prescription Doses' })).toBeVisible()
      },
      {
        spec: 'The dose repeats every day at 8:00 AM',
        check: async () => expect(page.getByTestId('schedule-list')).toContainText(/8:00 AM\s+Every day/)
      },
      {
        spec: 'The real write completes',
        check: async () => expect(page.getByRole('status')).toHaveText('Dose added.')
      }
    ]
  });

  await page.getByRole('link', { name: 'Settings' }).click();
  await page.getByLabel('Snooze interval').selectOption('15');
  await page.getByLabel('Escalate after').selectOption('45');
  await page.getByLabel('Maximum reminders').selectOption('4');
  await page.getByLabel('Administrator name').fill('Lori');
  await page.getByLabel('Plan name').fill("Lori's morning medication");
  await page.getByLabel('SMS number').fill('+1 226 747 5188');
  await page.getByRole('button', { name: 'Save changes' }).click();
  await tester.step('defaults-saved', {
    description: 'Lori sets reminder defaults and personal details',
    verifications: [
      {
        spec: 'The configurable snooze interval is saved',
        check: async () => expect(page.getByLabel('Snooze interval')).toHaveValue('15')
      },
      {
        spec: 'The escalation SMS number is saved',
        check: async () => expect(page.getByLabel('SMS number')).toHaveValue('+1 226 747 5188')
      },
      {
        spec: 'The dashboard confirms the settings write',
        check: async () => expect(page.getByRole('status')).toHaveText('Settings saved.')
      }
    ]
  });

  await page.getByRole('link', { name: 'Schedule' }).click();
  await page.getByRole('button', { name: 'Publish schedule' }).click();
  await tester.step('plan-published', {
    description: 'Lori publishes one discoverable medication plan',
    verifications: [
      {
        spec: 'The plan is published',
        check: async () => expect(page.getByText('Published', { exact: true })).toBeVisible()
      },
      {
        spec: 'A stable schedule code is visible',
        check: async () => expect(page.getByTestId('schedule-code')).toHaveText(/^[A-Z0-9]{4}-[A-Z0-9]{4}$/)
      },
      {
        spec: 'A share link can be copied',
        check: async () => expect(page.getByRole('button', { name: 'Copy link' })).toBeVisible()
      }
    ]
  });

  await page.getByRole('link', { name: 'Today', exact: true }).click();
  await tester.step('event-created', {
    description: 'The published dose has a live medication event',
    verifications: [
      {
        spec: 'The Today route receives the Firestore event',
        check: async () => expect(page.getByTestId('today-event-list')).toContainText('Morning Prescription Doses')
      },
      {
        spec: 'The event is waiting for a patient response',
        check: async () => expect(page.getByTestId('today-event-list')).toContainText('Pending')
      }
    ]
  });

  tester.generateDocs();
});
