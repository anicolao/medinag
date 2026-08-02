import type { AdvisorAccount } from './account-types';
import {
  accountLinkBanner,
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

function eventCard(event: MedicationEvent): string {
  const statusLabel = event.status === 'snoozed'
    ? `Snoozed${event.snoozeCount > 0 ? ` ×${event.snoozeCount}` : ''}`
    : event.status[0].toUpperCase() + event.status.slice(1);
  const detail = event.status === 'completed' && event.completedAt
    ? `Confirmed at ${timeFormatter.format(event.completedAt)}`
    : event.status === 'snoozed'
      ? 'Steve asked to be reminded again.'
      : 'Waiting for Steve to respond.';
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
  notice: string,
  repositoryMode: TodayRepository['mode'],
  account: AdvisorAccount
): string {
  const completed = events.filter(({ status }) => status === 'completed').length;
  const needsAttention = events.filter(({ status }) => status !== 'completed').length;
  const eventMarkup = events.length > 0
    ? events.map(eventCard).join('')
    : `
      <div class="empty-today">
        <span class="empty-calendar" aria-hidden="true"></span>
        <h3>No doses scheduled for today</h3>
        <p>Today's dose activity will appear here as Steve responds.</p>
        <a class="primary-button" href="#/schedules">Review schedules</a>
      </div>
    `;
  return `
    <div class="dashboard-shell">
      ${dashboardSidebar(account, 'today')}
      <main class="schedule-main today-main">
        ${accountLinkBanner(account)}
        <header class="schedule-header">
          <div>
            <p class="eyebrow">Steve's daily plan</p>
            <h1>Today</h1>
            <p>Follow every scheduled dose from reminder through confirmation.</p>
          </div>
        </header>

        <section class="schedule-summary" aria-label="Today's summary">
          <div><span>Completed</span><strong>${completed}</strong></div>
          <div><span>Needs attention</span><strong>${needsAttention}</strong></div>
          <p><span class="summary-dot" aria-hidden="true"></span>${connectionLabel(account, repositoryMode)}</p>
        </section>

        <section class="schedule-section" aria-labelledby="today-list-title">
          <div class="section-heading">
            <h2 id="today-list-title">Dose activity</h2>
            <p>Live status for Steve's medication plan.</p>
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
  account: AdvisorAccount,
  onReady: () => void
): () => void {
  let events: MedicationEvent[] = [];
  let notice = account.notice;
  let ready = false;

  const render = (): void => {
    root.innerHTML = pageTemplate(events, notice, repository.mode, account);
    const linkGoogle = root.querySelector<HTMLButtonElement>(
      '[data-action="link-google"]'
    );
    linkGoogle?.addEventListener('click', async () => {
      linkGoogle.disabled = true;
      linkGoogle.textContent = 'Opening Google…';
      try {
        await account.linkGoogle();
      } catch (error) {
        notice = error instanceof Error
          ? `Google account was not linked: ${error.message}`
          : 'Google account was not linked.';
        render();
      }
    });
    if (!ready) {
      ready = true;
      onReady();
    }
  };

  return repository.subscribe(
    (nextEvents) => {
      events = nextEvents;
      render();
    },
    (error) => {
      notice = `Unable to load today's doses: ${error.message}`;
      render();
    }
  );
}
