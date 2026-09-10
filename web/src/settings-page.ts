import type { AdministratorAccount } from './account-types';
import type { AdministratorRepository } from './administrator-repository';
import type { AdministratorProfile } from './administrator-types';
import {
  bindSignOut,
  dashboardSidebar,
  escapeHtml
} from './dashboard-markup';

const selectOptions = (values: number[], selected: number, suffix: string): string =>
  values.map((value) => `
    <option value="${value}"${value === selected ? ' selected' : ''}>${value} ${suffix}</option>
  `).join('');

function template(profile: AdministratorProfile, account: AdministratorAccount, notice: string): string {
  return `
    <div class="dashboard-shell">
      ${dashboardSidebar(account, 'settings')}
      <main class="schedule-main settings-main">
        <header class="schedule-header">
          <div>
            <p class="eyebrow">Settings</p>
            <h1>Defaults &amp; personal details</h1>
            <p>Set reminder preferences and keep your details up to date.</p>
          </div>
        </header>

        <form class="settings-form">
          <section class="settings-card" aria-labelledby="reminder-defaults-title">
            <div class="settings-card-heading">
              <h2 id="reminder-defaults-title">Reminder defaults</h2>
              <p>These values apply to every active dose in this plan.</p>
            </div>
            <div class="settings-grid">
              <label class="field">
                <span>Snooze interval</span>
                <select name="snoozeIntervalMinutes">
                  ${selectOptions([5, 10, 15, 20, 30], profile.snoozeIntervalMinutes, 'minutes')}
                </select>
              </label>
              <label class="field">
                <span>Escalate after</span>
                <select name="escalationDeadlineMinutes">
                  ${selectOptions([15, 30, 45, 60, 90], profile.escalationDeadlineMinutes, 'minutes')}
                </select>
              </label>
              <label class="field">
                <span>Maximum reminders</span>
                <select name="maxReminders">
                  ${selectOptions([1, 2, 3, 4, 5], profile.maxReminders, '')}
                </select>
              </label>
              <label class="field">
                <span>Plan time zone</span>
                <select name="timeZone">
                  <option value="America/Toronto"${profile.timeZone === 'America/Toronto' ? ' selected' : ''}>America/Toronto</option>
                  <option value="America/Vancouver"${profile.timeZone === 'America/Vancouver' ? ' selected' : ''}>America/Vancouver</option>
                  <option value="America/New_York"${profile.timeZone === 'America/New_York' ? ' selected' : ''}>America/New_York</option>
                  <option value="UTC"${profile.timeZone === 'UTC' ? ' selected' : ''}>UTC</option>
                </select>
              </label>
            </div>
          </section>

          <section class="settings-card" aria-labelledby="personal-details-title">
            <div class="settings-card-heading">
              <h2 id="personal-details-title">Personal details</h2>
              <p>Your name helps the patient find the right schedule.</p>
            </div>
            <div class="settings-grid">
              <label class="field">
                <span>Administrator name</span>
                <input name="displayName" type="text" maxlength="100" value="${escapeHtml(profile.displayName)}" required />
              </label>
              <label class="field">
                <span>Plan name</span>
                <input name="planName" type="text" maxlength="100" value="${escapeHtml(profile.planName)}" required />
              </label>
              <label class="field settings-wide-field">
                <span>SMS number</span>
                <input name="smsNumber" type="tel" maxlength="20" placeholder="+1 226 555 0100" value="${escapeHtml(profile.smsNumber)}" />
                <small>This number receives escalation alerts.</small>
              </label>
            </div>
            <div class="settings-actions">
              <button class="primary-button" type="submit">Save changes</button>
            </div>
          </section>
        </form>
        <p class="page-notice" role="status" aria-live="polite">${escapeHtml(notice)}</p>
      </main>
    </div>
  `;
}

export function mountSettingsPage(
  root: HTMLElement,
  repository: AdministratorRepository,
  account: AdministratorAccount,
  onReady: () => void
): () => void {
  let current: AdministratorProfile | undefined;
  let notice = account.notice;
  let ready = false;

  const render = (): void => {
    if (!current) return;
    root.innerHTML = template(current, account, notice);
    bindSignOut(root, account);
    const form = root.querySelector<HTMLFormElement>('.settings-form');
    form?.addEventListener('submit', async (event) => {
      event.preventDefault();
      const values = new FormData(form);
      const button = form.querySelector<HTMLButtonElement>('button[type="submit"]');
      if (button) {
        button.disabled = true;
        button.textContent = 'Saving…';
      }
      try {
        await repository.updateSettings({
          displayName: String(values.get('displayName')).trim(),
          planName: String(values.get('planName')).trim(),
          snoozeIntervalMinutes: Number(values.get('snoozeIntervalMinutes')),
          escalationDeadlineMinutes: Number(values.get('escalationDeadlineMinutes')),
          maxReminders: Number(values.get('maxReminders')),
          timeZone: String(values.get('timeZone')),
          smsNumber: String(values.get('smsNumber')).trim()
        });
        notice = 'Settings saved.';
        render();
      } catch (error) {
        notice = error instanceof Error ? error.message : 'Unable to save settings.';
        render();
      }
    });
  };

  return repository.subscribe(
    (profile) => {
      current = profile;
      render();
      if (!ready) {
        ready = true;
        onReady();
      }
    },
    (error) => {
      notice = `Unable to load settings: ${error.message}`;
      render();
    }
  );
}
