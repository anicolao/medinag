import { expect, test } from '@playwright/test';
import { TestStepHelper } from '../helpers/test-step-helper';

test('US-006: Watch completion reaches the administrator', async ({ page }, testInfo) => {
  const tester = new TestStepHelper(page, testInfo, 'web', 2);
  await page.goto('/#/today', { waitUntil: 'domcontentloaded' });
  await tester.step('watch-dashboard-completed', {
    description: 'The administrator receives the Watch completion through Firestore',
    verifications: [{ claim: 'watch.web.completed', check: async () => {
      const name = process.env.MEDINAG_E2E_MEDICATION_NAME;
      if (!name) throw new Error('Connected medication name is required.');
      await expect(page.getByTestId('today-event-list')).toContainText(name);
      await expect(page.getByTestId('today-event-list')).toContainText('Completed');
    } }]
  });
});
