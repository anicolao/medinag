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
import type {
  SystemHealthRepository,
  SystemHealthSnapshot
} from './system-health-repository';

function formatWallTime(value: string): string {
  const [hour, minute] = value.split(':').map(Number);
  const suffix = hour >= 12 ? 'PM' : 'AM';
  const displayHour = hour % 12 || 12;
  return `${displayHour}:${String(minute).padStart(2, '0')} ${suffix}`;
}

function formatInstant(value: Date, timeZone: string): string {
  return new Intl.DateTimeFormat('en-CA', {
    month: 'short',
    day: 'numeric',
    hour: 'numeric',
    minute: '2-digit',
    timeZone
  }).format(value);
}

function eventCard(event: MedicationEvent, patientName: string): string {
  const statusLabel = event.status === 'snoozed'
    ? `Snoozed${event.snoozeCount > 0 ? ` ×${event.snoozeCount}` : ''}`
    : event.status[0].toUpperCase() + event.status.slice(1);
  const detail = event.status === 'completed' && event.completedAt
      ? `${patientName} confirmed this dose.`
    : event.status === 'snoozed'
      ? `${patientName} asked to be reminded again.`
      : `Waiting for ${patientName} to respond.`;
  return `
    <article class="today-event-card ${event.status}">
      <time>${formatWallTime(event.scheduledLocalTime)}</time>
      <div>
        <h3>${escapeHtml(event.medicationName)}</h3>
        <p>${detail} <small>${escapeHtml(event.occurrenceDate)} · ${escapeHtml(event.timeZone)}</small></p>
      </div>
      <span class="event-status ${event.status}">${statusLabel}</span>
    </article>
  `;
}

function pageTemplate(
  events: MedicationEvent[],
  profile: AdministratorProfile,
  health: SystemHealthSnapshot,
  notice: string,
  account: AdministratorAccount
): string {
  const completed = events.filter(({ status }) => status === 'completed').length;
  const needsAttention = events.filter(({ status }) => status !== 'completed').length;
  const openIncidents = health.incidents
    .filter(({ status }) => status === 'open')
    .sort((left, right) => right.lastOccurredAt.getTime() - left.lastOccurredAt.getTime());
  const resolvedIncidents = health.incidents
    .filter(({ status }) => status === 'resolved')
    .sort((left, right) => right.lastOccurredAt.getTime() - left.lastOccurredAt.getTime());
  const coverage = health.coverage[0];
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
  const healthMarkup = coverage
    ? `
      <div class="coverage-card ${coverage.reconciliationStatus}">
        <div>
          <span>Patient reminder coverage</span>
          <strong>Scheduled through ${escapeHtml(formatInstant(coverage.scheduledThrough, coverage.timeZone))}</strong>
          <small>${escapeHtml(coverage.timeZone)} · ${coverage.actualPendingCount}/${coverage.expectedPendingCount} reminders confirmed by iOS</small>
        </div>
        <span class="event-status ${coverage.reconciliationStatus === 'ready' ? 'completed' : 'pending'}">${coverage.reconciliationStatus === 'ready' ? 'Ready' : 'Failed'}</span>
      </div>
    `
    : `
      <div class="coverage-card missing">
        <div>
          <span>Patient reminder coverage</span>
          <strong>No phone refresh has been reported</strong>
          <small>The administrator will be alerted if reminder coverage is unavailable.</small>
        </div>
        <span class="event-status pending">Not ready</span>
      </div>
    `;
  const incidentsMarkup = openIncidents.length > 0
    ? openIncidents.map((incident) => `
      <article class="incident-card ${incident.severity}" data-testid="system-incident">
        <div>
          <span>${incident.severity === 'critical' ? 'Critical incident' : 'Warning'}</span>
          <h3>${escapeHtml(incident.message)}</h3>
          <p>${escapeHtml(incident.code)} · occurred ${incident.occurrenceCount} time${incident.occurrenceCount === 1 ? '' : 's'}</p>
        </div>
        <span class="sms-state">SMS: ${escapeHtml(incident.smsState.replaceAll('_', ' '))}${incident.smsAttempts > 0 ? ` · attempt ${incident.smsAttempts}` : ''}${incident.smsProviderMessageId ? ` · ${escapeHtml(incident.smsProviderMessageId)}` : ''}</span>
      </article>
    `).join('')
    : '<p class="healthy-state">No open reminder-system incidents.</p>';
  const resolvedIncidentsMarkup = resolvedIncidents.map((incident) => `
    <article class="incident-card resolved" data-testid="resolved-system-incident">
      <div>
        <span>Resolved incident</span>
        <h3>${escapeHtml(incident.message)}</h3>
        <p>${escapeHtml(incident.code)} · recovered after ${incident.occurrenceCount} occurrence${incident.occurrenceCount === 1 ? '' : 's'}</p>
      </div>
      <span class="sms-state">SMS: ${escapeHtml(incident.smsState.replaceAll('_', ' '))}${incident.smsAttempts > 0 ? ` · attempt ${incident.smsAttempts}` : ''}${incident.smsProviderMessageId ? ` · ${escapeHtml(incident.smsProviderMessageId)}` : ''}</span>
    </article>
  `).join('');
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
        <section class="schedule-section health-section" aria-labelledby="system-health-title">
          <div class="section-heading">
            <h2 id="system-health-title">Reminder-system health</h2>
            <p>Phone coverage, failures, and administrator SMS escalation.</p>
          </div>
          <div data-testid="device-coverage">${healthMarkup}</div>
          <div class="incident-list" data-testid="system-incidents">${incidentsMarkup}${resolvedIncidentsMarkup}</div>
        </section>
        <p class="page-notice" role="status" aria-live="polite">${escapeHtml(notice)}</p>
      </main>
    </div>
  `;
}

export function mountTodayPage(
  root: HTMLElement,
  repository: TodayRepository,
  healthRepository: SystemHealthRepository,
  administrator: AdministratorRepository,
  account: AdministratorAccount,
  onReady: () => void
): () => void {
  let events: MedicationEvent[] = [];
  let profile: AdministratorProfile | undefined;
  let health: SystemHealthSnapshot = { coverage: [], incidents: [] };
  let notice = account.notice;
  let ready = false;

  const render = (): void => {
    if (!profile) return;
    root.innerHTML = pageTemplate(events, profile, health, notice, account);
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
  const unsubscribeHealth = healthRepository.subscribe(
    (nextHealth) => {
      health = nextHealth;
      render();
    },
    (error) => {
      notice = `Unable to load reminder-system health: ${error.message}`;
      render();
    }
  );
  return () => {
    unsubscribeEvents();
    unsubscribeAdministrator();
    unsubscribeHealth();
  };
}
