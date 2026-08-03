import type { AdvisorAccount } from './account-types';

export const escapeHtml = (value: string): string =>
  value.replace(
    /[&<>"']/g,
    (character) =>
      ({
        '&': '&amp;',
        '<': '&lt;',
        '>': '&gt;',
        '"': '&quot;',
        "'": '&#039;'
      })[character] ?? character
  );

export function dashboardSidebar(
  account: AdvisorAccount,
  active: 'today' | 'schedules'
): string {
  const displayName = escapeHtml(account.displayName || 'Lori');
  const subtitle = account.kind === 'google'
    ? 'Google account linked'
    : account.kind === 'migration-error'
      ? 'Google linked · action needed'
      : account.kind === 'anonymous'
        ? 'Guest advisor'
        : 'Advisor';
  const initial = escapeHtml(displayName.slice(0, 1).toUpperCase() || 'L');
  return `
    <aside class="dashboard-sidebar">
      <a class="dashboard-brand" href="#" aria-label="MediNag welcome">
        <span class="brand-mark" aria-hidden="true">
          <svg viewBox="0 0 40 40">
            <path d="M12 20a8 8 0 0 1 8-8h8a8 8 0 0 1 0 16h-8a8 8 0 0 1-8-8Z"></path>
            <path d="M20 12v16"></path>
          </svg>
        </span>
        <span class="brand-name">MediNag</span>
      </a>

      <nav class="dashboard-nav" aria-label="Admin dashboard">
        <a href="#/today"${active === 'today' ? ' class="active" aria-current="page"' : ''}>
          <span class="nav-icon overview-nav-icon" aria-hidden="true"></span>
          Today
        </a>
        <a href="#/schedules"${active === 'schedules' ? ' class="active" aria-current="page"' : ''}>
          <span class="nav-icon schedule-nav-icon" aria-hidden="true"></span>
          Schedules
        </a>
        <span class="nav-item" aria-disabled="true">
          <span class="nav-icon rules-nav-icon" aria-hidden="true"></span>
          Nag & escalation
        </span>
        <span class="nav-item" aria-disabled="true">
          <span class="nav-icon history-nav-icon" aria-hidden="true"></span>
          Compliance history
        </span>
      </nav>

      <div class="advisor-card">
        <span class="advisor-avatar" aria-hidden="true">${initial}</span>
        <span>
          <strong>${displayName}</strong>
          <small>${subtitle}</small>
        </span>
      </div>
    </aside>
  `;
}

export function accountLinkBanner(account: AdvisorAccount): string {
  if (account.kind === 'migration-error') {
    return `
      <section class="account-link-card migration-error" aria-labelledby="account-link-title">
        <span class="google-mark" aria-hidden="true">G</span>
        <div>
          <p class="eyebrow">Google account linked</p>
          <h2 id="account-link-title">Your schedules are safe</h2>
          <p>We could not finish moving them into the shared household. You can keep using the original schedules here and retry the migration safely.</p>
        </div>
        <button class="google-link-button" type="button" data-action="link-google">
          Retry migration
        </button>
      </section>
    `;
  }
  if (account.kind !== 'anonymous') {
    return '';
  }
  return `
    <section class="account-link-card" aria-labelledby="account-link-title">
      <span class="google-mark" aria-hidden="true">G</span>
      <div>
        <p class="eyebrow">Keep Lori's work</p>
        <h2 id="account-link-title">Link this dashboard to your Google account</h2>
        <p>Your existing schedules will move safely into your Google-linked household, then stay available whenever you sign in with Gmail.</p>
      </div>
      <button class="google-link-button" type="button" data-action="link-google">
        Continue with Google
      </button>
    </section>
  `;
}

export function connectionLabel(
  account: AdvisorAccount,
  mode: 'firestore' | 'preview'
): string {
  if (account.kind === 'google') {
    return 'Google account linked · Firebase synced';
  }
  if (account.kind === 'migration-error') {
    return 'Google linked · migration needs attention';
  }
  if (account.kind === 'anonymous') {
    return 'Firebase connected · guest workspace';
  }
  return mode === 'preview'
    ? 'Preview data · saved in this browser'
    : 'Firebase connected';
}
