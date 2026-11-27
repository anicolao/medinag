import { expect, test } from '@playwright/test';

// Functional connected diagnostic with real current time. Attachments are
// candidates for review, not approved deterministic zero-pixel baselines.
test('publish the medication and server timing settings through the real dashboard', async ({ page }, info) => {
  test.setTimeout(20_000);
  const name = process.env.MEDINAG_E2E_MEDICATION_NAME;
  const time = process.env.MEDINAG_E2E_SCHEDULED_TIME;
  if (!name || !time) throw new Error('Use the connected AlarmKit runner.');
  await page.goto('/#/schedules', { waitUntil: 'domcontentloaded' });
  await expect(page.getByText('No doses in this plan yet')).toBeVisible();
  await page.getByRole('link', { name: 'Settings' }).click();
  await page.getByLabel('Snooze interval').selectOption('5');
  await page.getByLabel('Repeat interval').selectOption('1');
  await page.getByLabel('SMS number').fill('+15555550199');
  await page.getByRole('button', { name: 'Save changes' }).click();
  await expect(page.getByRole('status')).toHaveText('Settings saved.');
  await page.getByRole('link', { name: 'Schedule', exact: true }).click();
  await page.getByRole('button', { name: 'Add dose' }).click();
  await page.getByLabel('Medication label').fill(name);
  await page.getByLabel('Dose time').fill(time);
  await page.getByRole('button', { name: 'Save dose' }).click();
  await expect(page.getByRole('status')).toHaveText('Dose added.');
  // Exercise two full 31-alarm blocks (one-minute retries through +30m).
  // These additional schedules also enter through the real visible web UI.
  for (const hours of [1, 2]) {
    const later = new Intl.DateTimeFormat('en-GB', { timeZone: 'America/Toronto',
      hour: '2-digit', minute: '2-digit', hourCycle: 'h23' })
      .format(new Date(Date.now() + hours * 60 * 60 * 1000));
    await page.getByRole('button', { name: 'Add dose' }).click();
    await page.getByLabel('Medication label').fill(`${name} later ${hours}`);
    await page.getByLabel('Dose time').fill(later);
    await page.getByRole('button', { name: 'Save dose' }).click();
    await expect(page.getByRole('status')).toHaveText('Dose added.');
  }
  await page.getByRole('button', { name: 'Publish schedule' }).click();
  await expect(page.getByRole('status')).toHaveText('Schedule published.');
  await info.attach('real-published-alarmkit-plan', { body: await page.screenshot(), contentType: 'image/png' });
});
