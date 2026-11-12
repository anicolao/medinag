import { expect, test } from '@playwright/test';
import { readFileSync } from 'node:fs';
import { TestStepHelper } from '../helpers/test-step-helper';

test.setTimeout(10_000);

test('US-005: Lori receives one captured failure alert', async ({ page }, testInfo) => {
  const smsNumber = process.env.MEDINAG_E2E_SMS_NUMBER;
  const captureFile = process.env.MEDINAG_E2E_SMS_CAPTURE_FILE;
  if (!smsNumber || !captureFile) throw new Error('The SMS capture environment is incomplete.');

  await page.goto('/#/today', { waitUntil: 'domcontentloaded' });
  const tester = new TestStepHelper(page, testInfo, 'web', 1);
  await tester.step('administrator-alerted', {
    description: 'Lori sees the incident and its captured SMS result',
    verifications: [
      {
        claim: 'failure.dashboard-incident',
        check: async () => {
          const incident = page.getByTestId('system-incident');
          await expect(incident).toContainText('notification_authorization_denied');
          await expect(incident).toContainText(
            'The patient iPhone has not allowed medication notifications.'
          );
        }
      },
      {
        claim: 'failure.provider-recorded',
        check: async () =>
          await expect(page.getByTestId('system-incident')).toContainText(
            'SMS: accepted · attempt 1 · SM-e2e-0001'
          )
      },
      {
        claim: 'failure.one-request',
        check: async () => {
          const lines = readFileSync(captureFile, 'utf8').trim().split('\n').filter(Boolean);
          expect(lines).toHaveLength(1);
          const request = JSON.parse(lines[0]) as Record<string, unknown>;
          expect(request).toMatchObject({
            method: 'POST',
            authenticated: true,
            to: smsNumber,
            from: '+15555550100',
            body: 'MediNag alert: The patient iPhone has not allowed medication notifications.',
            providerMessageId: 'SM-e2e-0001',
            providerState: 'queued'
          });
        }
      }
    ]
  });
});
