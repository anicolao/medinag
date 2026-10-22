import { expect, test } from '@playwright/test';
import { readFileSync } from 'node:fs';
import { TestStepHelper } from '../helpers/test-step-helper';

test.setTimeout(10_000);

test('US-005: observed recovery resolves the alert', async ({ page }, testInfo) => {
  const captureFile = process.env.MEDINAG_E2E_SMS_CAPTURE_FILE;
  if (!captureFile) throw new Error('MEDINAG_E2E_SMS_CAPTURE_FILE is required.');
  await page.goto('/#/today', { waitUntil: 'domcontentloaded' });
  const tester = new TestStepHelper(page, testInfo, 'web', 2);
  await tester.step('administrator-sees-recovery', {
    description: 'Lori sees observed recovery without a duplicate SMS',
    verifications: [
      {
        claim: 'recovery.resolved',
        check: async () => {
          await expect(page.getByTestId('system-incidents')).toContainText(
            'No open reminder-system incidents.'
          );
          await expect(page.getByTestId('resolved-system-incident')).toContainText(
            'notification_authorization_denied'
          );
        }
      },
      {
        claim: 'recovery.coverage',
        check: async () =>
          await expect(page.getByTestId('device-coverage')).toContainText('Ready')
      },
      {
        claim: 'recovery.no-duplicate',
        check: async () => {
          const requests = readFileSync(captureFile, 'utf8').trim().split('\n').filter(Boolean);
          expect(requests).toHaveLength(1);
        }
      }
    ]
  });
});
