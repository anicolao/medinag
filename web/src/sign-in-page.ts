import type { AdministratorAccount } from './account-types';
import { escapeHtml } from './dashboard-markup';

export function mountSignInPage(
  root: HTMLElement,
  account: AdministratorAccount,
  onReady: () => void
): () => void {
  let notice = account.notice;
  root.innerHTML = `
    <div class="admin-sign-in-shell">
      <aside class="sign-in-brand-panel">
        <div class="dashboard-brand">
          <span class="brand-mark" aria-hidden="true">
            <svg viewBox="0 0 40 40">
              <path d="M12 20a8 8 0 0 1 8-8h8a8 8 0 0 1 0 16h-8a8 8 0 0 1-8-8Z"></path>
              <path d="M20 12v16"></path>
            </svg>
          </span>
          <span class="brand-name">MediNag</span>
        </div>
      </aside>
      <main class="admin-sign-in-main">
        <section class="admin-sign-in-card" aria-labelledby="sign-in-title">
          <p class="eyebrow">Medication management</p>
          <h1 id="sign-in-title">Manage a medication schedule</h1>
          <p>Sign in to publish one schedule for someone you care about.</p>
          <button class="google-sign-in-button" type="button" data-action="sign-in-google">
            <span class="google-mark" aria-hidden="true">G</span>
            Continue with Google
          </button>
          <p class="page-notice" role="status" aria-live="polite">${escapeHtml(notice)}</p>
        </section>
      </main>
    </div>
  `;
  const button = root.querySelector<HTMLButtonElement>('[data-action="sign-in-google"]');
  button?.addEventListener('click', async () => {
    button.disabled = true;
    button.lastChild!.textContent = ' Opening Google…';
    try {
      await account.signInWithGoogle();
    } catch (error) {
      notice = error instanceof Error ? error.message : 'Google Sign-In failed.';
      const status = root.querySelector<HTMLElement>('[role="status"]');
      if (status) status.textContent = notice;
      button.disabled = false;
      button.lastChild!.textContent = ' Continue with Google';
    }
  });
  onReady();
  return () => undefined;
}
