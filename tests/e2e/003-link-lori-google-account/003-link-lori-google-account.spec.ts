import { expect, test } from '@playwright/test';
import { TestStepHelper } from '../helpers/test-step-helper';

test("US-003: Lori links her existing schedules to Google", async ({ page }, testInfo) => {
  const tester = new TestStepHelper(page, testInfo);
  tester.setMetadata(
    "Link Lori's Google account",
    "As Lori, I want to link my existing schedules to my Google account so that my work is preserved and ready to sync with Steve's devices."
  );

  await page.addInitScript(() => {
    window.__MEDINAG_E2E__ = true;
    window.__MEDINAG_E2E_ACCOUNT_LINK__ = true;
    if (sessionStorage.getItem('medinag:e2e-account-initialized') === 'true') {
      return;
    }
    localStorage.clear();
    sessionStorage.clear();
    sessionStorage.setItem('medinag:e2e-account-initialized', 'true');
    localStorage.setItem(
      'medinag:schedules:v1',
      JSON.stringify([
        {
          id: 'existing-morning-schedule',
          medicationName: 'Morning Prescription Doses',
          scheduledTime: '08:00',
          daysOfWeek: [1, 2, 3, 4, 5, 6, 7],
          active: true
        }
      ])
    );
    localStorage.setItem(
      'medinag:events:v1',
      JSON.stringify([
        {
          id: 'morning-dose',
          medicationName: 'Morning Prescription Doses',
          scheduledTime: '2026-08-02T12:00:00.000Z',
          status: 'completed',
          snoozeCount: 0,
          completedAt: '2026-08-02T12:07:00.000Z'
        }
      ])
    );
  });
  await page.goto('/#/schedules');

  await tester.step('existing-guest-schedules', {
    description: 'Lori sees that her guest schedules can move with her',
    verifications: [
      {
        spec: 'The dashboard is deterministically ready',
        check: async () =>
          await expect(page.locator('html')).toHaveAttribute('data-app-ready', 'true')
      },
      {
        spec: 'The Google linking explanation is visible',
        check: async () =>
          await expect(
            page.getByRole('heading', {
              name: 'Link this dashboard to your Google account'
            })
          ).toBeVisible()
      },
      {
        spec: 'Lori can see her existing medication schedule before linking',
        check: async () =>
          await expect(
            page.getByRole('heading', { name: 'Morning Prescription Doses' })
          ).toBeVisible()
      }
    ]
  });

  const reloaded = page.waitForEvent('load');
  await page.getByRole('button', { name: 'Continue with Google' }).click();
  await reloaded;

  await tester.step('google-account-linked', {
    description: "Lori links Gmail without losing the schedule she already entered",
    verifications: [
      {
        spec: 'The linked dashboard finishes rendering',
        check: async () =>
          await expect(page.locator('html')).toHaveAttribute('data-app-ready', 'true')
      },
      {
        spec: 'The dashboard confirms that Google and Firebase are connected',
        check: async () =>
          await expect(
            page.getByText('Google account linked · Firebase synced')
          ).toBeVisible()
      },
      {
        spec: 'The migration confirmation reports one preserved schedule',
        check: async () =>
          await expect(page.getByRole('status')).toHaveText(
            'Google account linked. 1 existing schedule was moved safely.'
          )
      },
      {
        spec: 'The existing schedule remains available after linking',
        check: async () =>
          await expect(
            page.getByRole('heading', { name: 'Morning Prescription Doses' })
          ).toBeVisible()
      }
    ]
  });

  await page.getByRole('link', { name: 'Today' }).click();

  await tester.step('today-status-visible', {
    description: "Lori sees Steve's latest dose status in the shared household",
    verifications: [
      {
        spec: 'The Today route finishes rendering',
        check: async () =>
          await expect(page.locator('html')).toHaveAttribute('data-app-ready', 'true')
      },
      {
        spec: 'The completed morning dose is visible',
        check: async () =>
          await expect(page.getByTestId('today-event-list')).toContainText(
            'Morning Prescription Doses'
          )
      },
      {
        spec: 'The dose status is completed',
        check: async () =>
          await expect(page.getByTestId('today-event-list')).toContainText('Completed')
      },
      {
        spec: 'The confirmation time is shown in Toronto time',
        check: async () =>
          await expect(page.getByTestId('today-event-list')).toContainText(
            'Confirmed at 8:07 a.m.'
          )
      }
    ]
  });

  tester.generateDocs();
});
