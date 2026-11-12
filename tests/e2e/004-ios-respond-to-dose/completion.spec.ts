import { expect, test } from '@playwright/test';
import { readFileSync } from 'node:fs';
import { TestStepHelper } from '../helpers/test-step-helper';

test.setTimeout(10_000);

test('US-004 completion returns to the administrator dashboard', async ({ page }, testInfo) => {
  const medicationName = process.env.MEDINAG_E2E_MEDICATION_NAME;
  if (!medicationName) {
    throw new Error('MEDINAG_E2E_MEDICATION_NAME must be supplied.');
  }

  await page.goto('/#/today', { waitUntil: 'domcontentloaded' });

  const tester = new TestStepHelper(page, testInfo, 'web', 2);
  await tester.step('completion-returned-to-dashboard', {
    description: "Lori sees Steve's completion and healthy iPhone coverage",
    verifications: [
      {
        claim: 'web.completed-occurrence',
        check: async () => {
          const events = page.getByTestId('today-event-list');
          await expect(events).toContainText(medicationName);
          await expect(events).toContainText('Completed');
        }
      },
      {
        claim: 'web.healthy-coverage',
        check: async () => {
          const coverage = page.getByTestId('device-coverage');
          await expect(coverage).toContainText('Ready');
          await expect(coverage).toContainText('reminders confirmed by iOS');
        }
      },
      {
        claim: 'web.no-open-incident',
        check: async () =>
          await expect(page.getByTestId('system-incidents')).toHaveText(
            'No open reminder-system incidents.'
          )
      },
      {
        claim: 'web.no-sms',
        check: async () => {
          const captureFile = process.env.MEDINAG_E2E_SMS_CAPTURE_FILE;
          if (!captureFile) throw new Error('MEDINAG_E2E_SMS_CAPTURE_FILE is required.');
          expect(readFileSync(captureFile, 'utf8')).toBe('');
        }
      }
    ]
  });
});
