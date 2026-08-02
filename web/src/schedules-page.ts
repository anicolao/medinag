import {
  DAYS,
  describeDays,
  formatTime,
  type MedicationSchedule
} from './schedule-types';
import type { ScheduleRepository } from './schedule-repository';
import type { AdvisorAccount } from './account-types';
import {
  accountLinkBanner,
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
  notice: string,
  repositoryMode: ScheduleRepository['mode'],
  account: AdvisorAccount
): string {
  const activeCount = schedules.filter(({ active }) => active).length;
  const scheduleMarkup =
    schedules.length > 0
      ? schedules.map(scheduleCard).join('')
      : `
        <div class="empty-schedules">
          <span class="empty-calendar" aria-hidden="true"></span>
          <h3>No medication schedules yet</h3>
          <p>Add Steve’s first dose time to begin the daily plan.</p>
          <button class="primary-button" type="button" data-action="add-empty">Add first schedule</button>
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
      ${dashboardSidebar(account, 'schedules')}

      <main class="schedule-main">
        ${accountLinkBanner(account)}
        <header class="schedule-header">
          <div>
            <p class="eyebrow">Steve’s daily plan</p>
            <h1>Medication schedules</h1>
            <p>Set the dose times that drive reminders on Steve’s iPhone and Apple Watch.</p>
          </div>
          <button class="primary-button" type="button" data-action="add">
            <span aria-hidden="true">＋</span>
            Add schedule
          </button>
        </header>

        <section class="schedule-summary" aria-label="Schedule summary">
          <div>
            <span>Active schedules</span>
            <strong>${activeCount}</strong>
          </div>
          <div>
            <span>Total schedules</span>
            <strong>${schedules.length}</strong>
          </div>
          <p>
            <span class="summary-dot" aria-hidden="true"></span>
            ${connectionLabel(account, repositoryMode)}
          </p>
        </section>

        <section class="schedule-section" aria-labelledby="schedule-list-title">
          <div class="section-heading">
            <div>
              <h2 id="schedule-list-title">Recurring doses</h2>
              <p>Schedules repeat on the selected days until paused.</p>
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
            <h2 id="schedule-dialog-title">Add schedule</h2>
          </div>
          <button class="dialog-close" type="button" data-action="close" aria-label="Close schedule form">×</button>
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
          <button class="primary-button" type="submit">Save schedule</button>
        </div>
      </form>
    </dialog>
  `;
}

export function mountSchedulesPage(
  root: HTMLElement,
  repository: ScheduleRepository,
  account: AdvisorAccount,
  onReady: () => void
): () => void {
  let schedules: MedicationSchedule[] = [];
  let notice = account.notice;
  let ready = false;

  const render = (): void => {
    root.innerHTML = pageTemplate(schedules, notice, repository.mode, account);
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
        title.textContent = schedule ? 'Edit schedule' : 'Add schedule';
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
        notice = schedule.active ? 'Schedule paused.' : 'Schedule resumed.';
        try {
          await repository.setActive(schedule.id, !schedule.active);
        } catch (error) {
          notice = error instanceof Error ? error.message : 'Unable to update the schedule.';
          render();
        }
      });
    });
    root
      .querySelectorAll<HTMLElement>('[data-action="close"], [data-action="cancel"]')
      .forEach((button) => button.addEventListener('click', closeDialog));

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
        notice = scheduleId ? 'Schedule updated.' : 'Schedule added.';
        if (scheduleId) {
          await repository.update(scheduleId, input);
        } else {
          await repository.create(input);
        }
        closeDialog();
      } catch (error) {
        notice = error instanceof Error ? error.message : 'Unable to save the schedule.';
        if (submit) {
          submit.disabled = false;
          submit.textContent = 'Save schedule';
        }
        render();
      }
    });

    if (!ready) {
      ready = true;
      onReady();
    }
  };

  return repository.subscribe(
    (nextSchedules) => {
      schedules = nextSchedules;
      render();
    },
    (error) => {
      notice = `Unable to load schedules: ${error.message}`;
      render();
    }
  );
}
