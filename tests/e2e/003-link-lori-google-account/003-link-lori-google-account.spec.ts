import { expect, test } from '@playwright/test';
import { TestStepHelper } from '../helpers/test-step-helper';

test('US-003: anyone can become an administrator with Google', async ({ page }, testInfo) => {
  const tester = new TestStepHelper(page, testInfo);
  tester.setMetadata(
    'Become an administrator with Google',
    'As a family member, I want to sign in with Google so that I can publish one medication plan.'
  );

  await page.goto('/');
  await tester.step('administrator-sign-in', {
    description: 'A signed-out visitor sees the administrator entry point',
    verifications: [
      {
        spec: 'The page explains the administrator purpose',
        check: async () => expect(page.getByRole('heading', { name: 'Manage a medication schedule' })).toBeVisible()
      },
      {
        spec: 'Google is the only sign-in method',
        check: async () => expect(page.getByRole('button', { name: 'Continue with Google' })).toBeVisible()
      },
      {
        spec: 'No email or password fields are present',
        check: async () => expect(page.locator('input')).toHaveCount(0)
      }
    ]
  });

  const popupPromise = page.waitForEvent('popup');
  await page.getByRole('button', { name: 'Continue with Google' }).click();
  const popup = await popupPromise;
  await popup.waitForLoadState('domcontentloaded');
  await popup.locator('.js-new-account').click();
  await expect(popup.locator('#add-user')).toBeVisible();
  await popup.locator('#email-input').fill('new-administrator@medinag.invalid');
  await popup.locator('#display-name-input').fill('New Administrator');
  await popup.getByRole('button', { name: 'Sign in with Google.com' }).click();
  await popup.waitForEvent('close');

  await tester.step('administrator-created', {
    description: 'Google Sign-In creates a new administrator plan',
    verifications: [
      {
        spec: 'The authenticated dashboard finishes rendering',
        check: async () => expect(page.locator('html')).toHaveAttribute('data-app-ready', 'true')
      },
      {
        spec: 'The visitor is identified as an administrator',
        check: async () => expect(page.getByText('Administrator', { exact: true })).toBeVisible()
      },
      {
        spec: 'A single unpublished plan is ready for its first dose',
        check: async () => expect(page.getByText('No doses in this plan yet')).toBeVisible()
      },
      {
        spec: 'No household linking step appears',
        check: async () => expect(page.getByText(/household/i)).toHaveCount(0)
      }
    ]
  });

  tester.generateDocs();
});
