import {
  DAYS,
  describeDays,
  formatTime,
  type MedicationSchedule
} from './schedule-types';
import type { ScheduleRepository } from './schedule-repository';
import type { AdministratorAccount } from './account-types';
import type { AdministratorRepository } from './administrator-repository';
import type { AdministratorProfile } from './administrator-types';
import {
  bindSignOut,
  connectionLabel,
  dashboardSidebar,
  escapeHtml
} from './dashboard-markup';

function scheduleCard(schedule: MedicationSchedule): string {
  const name = escapeHtml(schedule.medicationName);
  return `
    <article class="schedule-card${schedule.active ? '' : ' is-paused'}" data-schedule-id="${schedule.id}">
      <div class="schedule-time">
        <strong>${formatTime(schedule.scheduledTime)}</strong>
        <span>${describeDays(schedule.daysOfWeek)}</span>
      </div>
      <div class="schedule-details">
        <div class="schedule-title-row">
          <h3>${name}</h3>
          <span class="schedule-state ${schedule.active ? 'active' : 'paused'}">
            ${schedule.active ? 'Active' : 'Paused'}
          </span>
        </div>
        <p>${schedule.active ? 'Reminders and escalation are enabled.' : 'No reminders will be sent.'}</p>
      </div>
      <div class="schedule-actions">
        <button class="secondary-button" type="button" data-action="edit" aria-label="Edit ${name}">
          Edit
        </button>
        <button class="text-button" type="button" data-action="toggle" aria-label="${schedule.active ? 'Pause' : 'Resume'} ${name}">
          ${schedule.active ? 'Pause' : 'Resume'}
        </button>
      </div>
    </article>
  `;
}

function pageTemplate(
  schedules: MedicationSchedule[],
  profile: AdministratorProfile,
  notice: string,
  account: AdministratorAccount
): string {
  const activeCount = schedules.filter(({ active }) => active).length;
  const scheduleMarkup =
    schedules.length > 0
      ? schedules.map(scheduleCard).join('')
      : `
        <div class="empty-schedules">
          <span class="empty-calendar" aria-hidden="true"></span>
          <h3>No doses in this plan yet</h3>
          <p>Add the first medication time before publishing this schedule.</p>
          <button class="primary-button" type="button" data-action="add-empty">Add first dose</button>
        </div>
      `;
  const dayInputs = DAYS.map(
    ({ value, short, long }) => `
      <label class="day-option">
        <input type="checkbox" name="daysOfWeek" value="${value}" checked />
        <span title="${long}">${short}</span>
      </label>
    `
  ).join('');

  return `
    <div class="dashboard-shell">
      ${dashboardSidebar(account, 'schedule')}

      <main class="schedule-main">
        <header class="schedule-header">
          <div>
            <p class="eyebrow">Medication management</p>
            <h1>Your medication schedule</h1>
            <p>Publish and manage one plan for someone you care about.</p>
          </div>
          <button class="primary-button" type="button" data-action="add">
            <span aria-hidden="true">+</span>
            Add dose
          </button>
        </header>

        <section class="publication-card" aria-label="Publication and sharing">
          <div>
            <span class="publication-status ${profile.published ? 'published' : 'draft'}">${profile.published ? 'Published' : 'Draft'}</span>
            <h2>${escapeHtml(profile.planName)}</h2>
            <p>${profile.published ? 'A patient can find this plan by name, code, or link.' : 'Add an active dose, review Settings, then publish this plan.'}</p>
          </div>
          <div class="plan-code-block">
            <span>Schedule code</span>
            <strong data-testid="schedule-code">${escapeHtml(profile.planCode)}</strong>
          </div>
          ${profile.published
            ? `<button class="secondary-button" type="button" data-action="copy-link">Copy link</button>`
            : `<button class="primary-button" type="button" data-action="publish"${activeCount === 0 ? ' disabled' : ''}>Publish schedule</button>`}
        </section>

        <section class="schedule-summary" aria-label="Schedule summary">
          <div><span>Active doses</span><strong>${activeCount}</strong></div>
          <div><span>Total doses</span><strong>${schedules.length}</strong></div>
          <p><span class="summary-dot" aria-hidden="true"></span>${connectionLabel()}</p>
        </section>

        <section class="patient-link-card" aria-label="Patient relationship">
          <div>
            <span>Patient</span>
            <strong>${profile.patientUid ? escapeHtml(profile.patientDisplayName || 'Linked patient') : 'Waiting for a patient'}</strong>
            <p>${profile.patientUid ? 'This patient receives the published plan.' : 'Share the code after publishing. The first patient to follow it becomes linked.'}</p>
          </div>
          ${profile.patientUid ? '<button class="text-button" type="button" data-action="disconnect-patient">Disconnect patient</button>' : ''}
        </section>

        <section class="schedule-section" aria-labelledby="schedule-list-title">
          <div class="section-heading">
            <div>
              <h2 id="schedule-list-title">Recurring doses</h2>
              <p>Doses repeat on the selected days until paused.</p>
            </div>
          </div>
          <div class="schedule-list" data-testid="schedule-list">
            ${scheduleMarkup}
          </div>
        </section>

        <p class="page-notice" role="status" aria-live="polite">${escapeHtml(notice)}</p>
      </main>
    </div>

    <dialog class="schedule-dialog" aria-labelledby="schedule-dialog-title">
      <form class="schedule-form">
        <div class="dialog-heading">
          <div>
            <p class="eyebrow">Medication timing</p>
            <h2 id="schedule-dialog-title">Add dose</h2>
          </div>
          <button class="dialog-close" type="button" data-action="close" aria-label="Close dose form">×</button>
        </div>

        <label class="field">
          <span>Medication label</span>
          <input name="medicationName" type="text" maxlength="100" placeholder="e.g. Morning meds — 2 pills" required />
          <small>Steve will see this exact label in reminders.</small>
        </label>

        <label class="field time-field">
          <span>Dose time</span>
          <input name="scheduledTime" type="time" value="08:00" required />
        </label>

        <fieldset class="days-field">
          <legend>Repeat on</legend>
          <div class="day-options">${dayInputs}</div>
          <p class="field-error" data-testid="days-error"></p>
        </fieldset>

        <div class="dialog-actions">
          <button class="secondary-button" type="button" data-action="cancel">Cancel</button>
          <button class="primary-button" type="submit">Save dose</button>
        </div>
      </form>
    </dialog>
  `;
}

export function mountSchedulesPage(
  root: HTMLElement,
  repository: ScheduleRepository,
  administrator: AdministratorRepository,
  account: AdministratorAccount,
  onReady: () => void
): () => void {
  let schedules: MedicationSchedule[] = [];
  let profile: AdministratorProfile | undefined;
  let notice = account.notice;
  let ready = false;

  const render = (): void => {
    if (!profile) return;
    root.innerHTML = pageTemplate(schedules, profile, notice, account);
    bindSignOut(root, account);
    const dialog = root.querySelector<HTMLDialogElement>('.schedule-dialog');
    const form = root.querySelector<HTMLFormElement>('.schedule-form');
    if (!dialog || !form) {
      throw new Error('Schedule form failed to render.');
    }

    const closeDialog = (): void => {
      if (dialog.open) {
        dialog.close();
      }
    };

    const openDialog = (schedule?: MedicationSchedule): void => {
      form.reset();
      for (const checkbox of form.querySelectorAll<HTMLInputElement>(
        'input[name="daysOfWeek"]'
      )) {
        checkbox.checked = schedule
          ? schedule.daysOfWeek.includes(Number(checkbox.value))
          : true;
      }
      const title = form.querySelector<HTMLHeadingElement>('#schedule-dialog-title');
      const name = form.elements.namedItem('medicationName') as HTMLInputElement;
      const time = form.elements.namedItem('scheduledTime') as HTMLInputElement;
      form.dataset.scheduleId = schedule?.id ?? '';
      if (title) {
        title.textContent = schedule ? 'Edit dose' : 'Add dose';
      }
      name.value = schedule?.medicationName ?? '';
      time.value = schedule?.scheduledTime ?? '08:00';
      dialog.showModal();
      name.focus();
    };

    root
      .querySelectorAll<HTMLElement>('[data-action="add"], [data-action="add-empty"]')
      .forEach((button) => button.addEventListener('click', () => openDialog()));
    root.querySelectorAll<HTMLButtonElement>('[data-action="edit"]').forEach((button) => {
      button.addEventListener('click', () => {
        const id = button.closest<HTMLElement>('[data-schedule-id]')?.dataset.scheduleId;
        openDialog(schedules.find((schedule) => schedule.id === id));
      });
    });
    root.querySelectorAll<HTMLButtonElement>('[data-action="toggle"]').forEach((button) => {
      button.addEventListener('click', async () => {
        const id = button.closest<HTMLElement>('[data-schedule-id]')?.dataset.scheduleId;
        const schedule = schedules.find((candidate) => candidate.id === id);
        if (!schedule) {
          return;
        }
        notice = schedule.active ? 'Dose paused.' : 'Dose resumed.';
        try {
          await repository.setActive(schedule.id, !schedule.active);
        } catch (error) {
          notice = error instanceof Error ? error.message : 'Unable to update the dose.';
          render();
        }
      });
    });
    root
      .querySelectorAll<HTMLElement>('[data-action="close"], [data-action="cancel"]')
      .forEach((button) => button.addEventListener('click', closeDialog));

    root.querySelector<HTMLButtonElement>('[data-action="publish"]')
      ?.addEventListener('click', async () => {
      if (schedules.every(({ active }) => !active)) return;
      try {
        await administrator.publish();
        notice = 'Schedule published.';
      } catch (error) {
        notice = error instanceof Error ? error.message : 'Unable to publish the schedule.';
        render();
      }
    });

    root.querySelector<HTMLButtonElement>('[data-action="copy-link"]')
      ?.addEventListener('click', async () => {
        const link = `${window.location.origin}${window.location.pathname}?schedule=${encodeURIComponent(profile!.planCode)}`;
        await navigator.clipboard.writeText(link);
        notice = 'Schedule link copied.';
        render();
      });

    root.querySelector<HTMLButtonElement>('[data-action="disconnect-patient"]')
      ?.addEventListener('click', async () => {
        if (!window.confirm(`Disconnect ${profile!.patientDisplayName || 'the linked patient'} from this schedule?`)) return;
        try {
          await administrator.disconnectPatient();
          notice = 'Patient disconnected.';
        } catch (error) {
          notice = error instanceof Error ? error.message : 'Unable to disconnect the patient.';
          render();
        }
      });

    form.addEventListener('submit', async (event) => {
      event.preventDefault();
      const selectedDays = Array.from(
        form.querySelectorAll<HTMLInputElement>('input[name="daysOfWeek"]:checked')
      ).map(({ value }) => Number(value));
      const daysError = form.querySelector<HTMLElement>('[data-testid="days-error"]');
      if (selectedDays.length === 0) {
        if (daysError) {
          daysError.textContent = 'Choose at least one day.';
        }
        return;
      }

      const name = form.elements.namedItem('medicationName') as HTMLInputElement;
      const time = form.elements.namedItem('scheduledTime') as HTMLInputElement;
      const scheduleId = form.dataset.scheduleId;
      const input = {
        medicationName: name.value.trim(),
        scheduledTime: time.value,
        daysOfWeek: selectedDays,
        active: scheduleId
          ? schedules.find((schedule) => schedule.id === scheduleId)?.active ?? true
          : true
      };
      const submit = form.querySelector<HTMLButtonElement>('button[type="submit"]');
      if (submit) {
        submit.disabled = true;
        submit.textContent = 'Saving…';
      }

      try {
        notice = scheduleId ? 'Dose updated.' : 'Dose added.';
        if (scheduleId) {
          await repository.update(scheduleId, input);
        } else {
          await repository.create(input);
        }
        closeDialog();
      } catch (error) {
        notice = error instanceof Error ? error.message : 'Unable to save the dose.';
        if (submit) {
          submit.disabled = false;
          submit.textContent = 'Save dose';
        }
        render();
      }
    });

    if (!ready) {
      ready = true;
      onReady();
    }
  };

  const unsubscribeSchedules = repository.subscribe(
    (nextSchedules) => {
      schedules = nextSchedules;
      render();
    },
    (error) => {
      notice = `Unable to load schedules: ${error.message}`;
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
    unsubscribeSchedules();
    unsubscribeAdministrator();
  };
}
