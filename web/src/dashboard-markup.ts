import type { AdministratorAccount } from './account-types';

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
  account: AdministratorAccount,
  active: 'today' | 'schedule' | 'settings'
): string {
  const displayName = escapeHtml(account.displayName || 'Administrator');
  const initial = escapeHtml(displayName.slice(0, 1).toUpperCase() || 'A');
  return `
    <aside class="dashboard-sidebar">
      <a class="dashboard-brand" href="#/today" aria-label="MediNag Today">
        <span class="brand-mark" aria-hidden="true">
          <svg viewBox="0 0 40 40">
            <path d="M12 20a8 8 0 0 1 8-8h8a8 8 0 0 1 0 16h-8a8 8 0 0 1-8-8Z"></path>
            <path d="M20 12v16"></path>
          </svg>
        </span>
        <span class="brand-name">MediNag</span>
      </a>

      <nav class="dashboard-nav" aria-label="Administrator dashboard">
        <a href="#/today"${active === 'today' ? ' class="active" aria-current="page"' : ''}>
          <span class="nav-icon overview-nav-icon" aria-hidden="true"></span>
          Today
        </a>
        <a href="#/schedules"${active === 'schedule' ? ' class="active" aria-current="page"' : ''}>
          <span class="nav-icon schedule-nav-icon" aria-hidden="true"></span>
          Schedule
        </a>
        <a href="#/settings"${active === 'settings' ? ' class="active" aria-current="page"' : ''}>
          <span class="nav-icon rules-nav-icon" aria-hidden="true"></span>
          Settings
        </a>
      </nav>

      <div class="advisor-card">
        <span class="advisor-avatar" aria-hidden="true">${initial}</span>
        <span>
          <strong>${displayName}</strong>
          <small>Administrator</small>
        </span>
        <button class="sidebar-sign-out" type="button" data-action="sign-out">Sign out</button>
      </div>
    </aside>
  `;
}

export function bindSignOut(
  root: HTMLElement,
  account: AdministratorAccount
): void {
  root.querySelector<HTMLButtonElement>('[data-action="sign-out"]')
    ?.addEventListener('click', async () => account.signOut());
}

export function connectionLabel(): string {
  return 'Google signed in · Firebase synced';
}
