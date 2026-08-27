import { expect, test } from '@playwright/test';
import { TestStepHelper } from '../helpers/test-step-helper';

test('US-003: Lori links her existing schedules to Google', async ({ page }, testInfo) => {
  const tester = new TestStepHelper(page, testInfo);
  tester.setMetadata(
    "Link Lori's Google account",
    "As Lori, I want to link my existing schedules to my Google account so that my work is preserved and ready to sync with Steve's devices."
  );

  await page.goto('/#/schedules');
  await page.getByRole('button', { name: 'Add schedule' }).click();
  await page.getByLabel('Medication label').fill('Morning Prescription Doses');
  await page.getByLabel('Dose time').fill('08:00');
  await page.getByRole('button', { name: 'Save schedule' }).click();

  await tester.step('existing-guest-schedules', {
    description: 'Lori sees the schedule she entered in her anonymous Firebase workspace',
    verifications: [
      {
        spec: 'The dashboard is connected as an anonymous Firebase user',
        check: async () =>
          await expect(page.getByText('Firebase connected · guest workspace')).toBeVisible()
      },
      {
        spec: 'The real Google linking action is available',
        check: async () =>
          await expect(
            page.getByRole('heading', {
              name: 'Link this dashboard to your Google account'
            })
          ).toBeVisible()
      },
      {
        spec: 'The schedule written through the UI is visible before linking',
        check: async () =>
          await expect(
            page.getByRole('heading', { name: 'Morning Prescription Doses' })
          ).toBeVisible()
      }
    ]
  });

  const popupPromise = page.waitForEvent('popup');
  await page.getByRole('button', { name: 'Continue with Google' }).click();
  const popup = await popupPromise;
  await popup.waitForLoadState('domcontentloaded');
  await popup.locator('.js-new-account').click();
  await expect(popup.locator('#add-user')).toBeVisible();
  await popup.locator('#email-input').fill('lori@medinag.invalid');
  await popup.locator('#display-name-input').fill('Lori Medina');
  await popup.getByRole('button', { name: 'Sign in with Google.com' }).click();
  await popup.waitForEvent('close');

  await tester.step('google-account-linked', {
    description: 'Lori links a Google-provider identity and Firestore migrates her schedule',
    verifications: [
      {
        spec: 'The linked dashboard finishes rendering after the real Auth callback',
        check: async () =>
          await expect(page.locator('html')).toHaveAttribute('data-app-ready', 'true')
      },
      {
        spec: 'The dashboard reports the linked Firebase identity',
        check: async () =>
          await expect(page.getByText('Google account linked · Firebase synced')).toBeVisible()
      },
      {
        spec: 'The migration confirms one preserved Firestore schedule',
        check: async () =>
          await expect(page.getByRole('status')).toHaveText(
            '1 existing schedule was moved safely.'
          )
      },
      {
        spec: 'The migrated schedule arrives from the household Firestore collection',
        check: async () =>
          await expect(
            page.getByRole('heading', { name: 'Morning Prescription Doses' })
          ).toBeVisible()
      }
    ]
  });

  tester.generateDocs();
});
