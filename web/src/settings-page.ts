import type { AdministratorAccount } from './account-types';
import type { AdministratorRepository } from './administrator-repository';
import type { AdministratorProfile } from './administrator-types';
import { assessReminderCoverage } from './reminder-coverage';
import {
  bindSignOut,
  dashboardSidebar,
  escapeHtml
} from './dashboard-markup';

const selectOptions = (values: number[], selected: number, suffix: string): string =>
  values.map((value) => `
    <option value="${value}"${value === selected ? ' selected' : ''}>${value} ${suffix}</option>
  `).join('');

function coverageMarkup(repeat: number, snooze: number): string {
  const assessment = assessReminderCoverage(repeat, snooze);
  return assessment.warnings.length
    ? `<p role="alert" data-testid="coverage-warning">${assessment.warnings.map(escapeHtml).join(' ')}</p>`
    : `<p data-testid="coverage-summary">Two full 30-minute dose windows use ${assessment.requiredSlots} of 60 notification slots. The current and next dose are reserved first; further dose windows are added while space allows. This confirms capacity, not a guarantee of OS presentation or a background wake.</p>`;
}

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
              <p>Repeat and snooze intervals apply to all your schedules.</p>
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
                <span>Repeat interval</span>
                <select name="repeatIntervalMinutes">
                  ${selectOptions([1, 2, 3, 5, 10, 15], profile.repeatIntervalMinutes, 'minutes')}
                </select>
              </label>
              <div class="patient-time-zone-note settings-wide-field">
                <span>Patient-local time</span>
                <strong>Dose times follow the patient’s current time zone.</strong>
                <small>The iPhone reports its time zone when it follows this schedule and whenever it refreshes.</small>
              </div>
            </div>
            <div data-testid="coverage-assessment" aria-live="polite">${coverageMarkup(profile.repeatIntervalMinutes, profile.snoozeIntervalMinutes)}</div>
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
    form?.addEventListener('change', () => {
      const values = new FormData(form);
      const assessment = root.querySelector('[data-testid="coverage-assessment"]');
      if (assessment) assessment.innerHTML = coverageMarkup(
        Number(values.get('repeatIntervalMinutes')), Number(values.get('snoozeIntervalMinutes')));
    });
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
          repeatIntervalMinutes: Number(values.get('repeatIntervalMinutes')),
          escalationDeadlineMinutes: Number(values.get('escalationDeadlineMinutes')),
          maxReminders: current!.maxReminders,
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
