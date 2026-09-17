import type { AdministratorAccount } from './account-types';
import type { AdministratorRepository } from './administrator-repository';
import type { AdministratorProfile } from './administrator-types';
import {
  bindSignOut,
  connectionLabel,
  dashboardSidebar,
  escapeHtml
} from './dashboard-markup';
import type { MedicationEvent } from './medication-event-types';
import type { TodayRepository } from './today-repository';

const timeFormatter = new Intl.DateTimeFormat('en-CA', {
  hour: 'numeric',
  minute: '2-digit',
  timeZone: 'America/Toronto'
});

function eventCard(event: MedicationEvent, patientName: string): string {
  const statusLabel = event.status === 'snoozed'
    ? `Snoozed${event.snoozeCount > 0 ? ` ×${event.snoozeCount}` : ''}`
    : event.status[0].toUpperCase() + event.status.slice(1);
  const detail = event.status === 'completed' && event.completedAt
      ? `Confirmed at ${timeFormatter.format(event.completedAt)}`
    : event.status === 'snoozed'
      ? `${patientName} asked to be reminded again.`
      : `Waiting for ${patientName} to respond.`;
  return `
    <article class="today-event-card ${event.status}">
      <time>${timeFormatter.format(event.scheduledTime)}</time>
      <div>
        <h3>${escapeHtml(event.medicationName)}</h3>
        <p>${detail}</p>
      </div>
      <span class="event-status ${event.status}">${statusLabel}</span>
    </article>
  `;
}

function pageTemplate(
  events: MedicationEvent[],
  profile: AdministratorProfile,
  notice: string,
  account: AdministratorAccount
): string {
  const completed = events.filter(({ status }) => status === 'completed').length;
  const needsAttention = events.filter(({ status }) => status !== 'completed').length;
  const eventMarkup = events.length > 0
    ? events.map((event) => eventCard(event, profile.patientDisplayName || 'the patient')).join('')
    : `
      <div class="empty-today">
        <span class="empty-calendar" aria-hidden="true"></span>
        <h3>No doses scheduled for today</h3>
        <p>Today's dose activity will appear here as the patient responds.</p>
        <a class="primary-button" href="#/schedules">Review schedules</a>
      </div>
    `;
  return `
    <div class="dashboard-shell">
      ${dashboardSidebar(account, 'today')}
      <main class="schedule-main today-main">
        <header class="schedule-header">
          <div>
            <p class="eyebrow">${escapeHtml(profile.planName)}</p>
            <h1>Today</h1>
            <p>Follow every scheduled dose from reminder through confirmation.</p>
          </div>
        </header>

        <section class="schedule-summary" aria-label="Today's summary">
          <div><span>Completed</span><strong>${completed}</strong></div>
          <div><span>Needs attention</span><strong>${needsAttention}</strong></div>
          <p><span class="summary-dot" aria-hidden="true"></span>${connectionLabel()}</p>
        </section>

        <section class="schedule-section" aria-labelledby="today-list-title">
          <div class="section-heading">
            <h2 id="today-list-title">Dose activity</h2>
            <p>${profile.patientUid ? `Live status for ${escapeHtml(profile.patientDisplayName || 'the linked patient')}.` : 'Publish the schedule and share its code to connect a patient.'}</p>
          </div>
          <div class="today-event-list" data-testid="today-event-list">${eventMarkup}</div>
        </section>
        <p class="page-notice" role="status" aria-live="polite">${escapeHtml(notice)}</p>
      </main>
    </div>
  `;
}

export function mountTodayPage(
  root: HTMLElement,
  repository: TodayRepository,
  administrator: AdministratorRepository,
  account: AdministratorAccount,
  onReady: () => void
): () => void {
  let events: MedicationEvent[] = [];
  let profile: AdministratorProfile | undefined;
  let notice = account.notice;
  let ready = false;

  const render = (): void => {
    if (!profile) return;
    root.innerHTML = pageTemplate(events, profile, notice, account);
    bindSignOut(root, account);
    if (!ready) {
      ready = true;
      onReady();
    }
  };

  const unsubscribeEvents = repository.subscribe(
    (nextEvents) => {
      events = nextEvents;
      render();
    },
    (error) => {
      notice = `Unable to load today's doses: ${error.message}`;
      render();
    }
  );
  const unsubscribeAdministrator = administrator.subscribe(
    (nextProfile) => {
      profile = nextProfile;
      render();
    },
    (error) => {
      notice = `Unable to load the plan: ${error.message}`;
      render();
    }
  );
  return () => {
    unsubscribeEvents();
    unsubscribeAdministrator();
  };
}
