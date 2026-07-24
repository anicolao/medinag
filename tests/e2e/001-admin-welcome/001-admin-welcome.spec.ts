import { expect, test } from '@playwright/test';
import { TestStepHelper } from '../helpers/test-step-helper';

test('US-001: Lori opens the admin dashboard', async ({ page }, testInfo) => {
  const tester = new TestStepHelper(page, testInfo);
  tester.setMetadata(
    'Admin dashboard welcome',
    'As Lori, I want to open the MediNag dashboard so that I know my advisor workspace is ready.'
  );

  await page.goto('/');

  await tester.step('welcome-page', {
    description: 'Lori sees the MediNag advisor welcome page',
    verifications: [
      {
        spec: 'The dashboard signals that deterministic rendering is ready',
        check: async () =>
          await expect(page.locator('html')).toHaveAttribute('data-app-ready', 'true')
      },
      {
        spec: 'The browser title identifies MediNag Admin',
        check: async () => await expect(page).toHaveTitle('MediNag Admin')
      },
      {
        spec: 'The welcome heading addresses Lori',
        check: async () =>
          await expect(page.getByRole('heading', { level: 1 })).toHaveText('Welcome, Lori.')
      },
      {
        spec: 'The dashboard reports that its foundation is online',
        check: async () =>
          await expect(page.getByLabel('Dashboard foundation status')).toContainText(
            'Dashboard foundation online'
          )
      },
      {
        spec: 'The upcoming dashboard capabilities are visible',
        check: async () =>
          await expect(page.getByLabel('Upcoming dashboard capabilities')).toBeVisible()
      }
    ]
  });

  tester.generateDocs();
});
