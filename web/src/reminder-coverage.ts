export const NOTIFICATION_CAPACITY = 60;
export const PROTECTION_MINUTES = 30;

export function assessReminderCoverage(repeatMinutes: number, snoozeMinutes: number): {
  requiredSlots: number;
  warnings: string[];
} {
  if (!Number.isFinite(repeatMinutes) || repeatMinutes < 1) {
    return { requiredSlots: 0, warnings: ['Choose a valid repeat interval of at least one minute.'] };
  }
  const requiredSlots = 2 * (Math.floor(PROTECTION_MINUTES / repeatMinutes) + 1);
  const warnings: string[] = [];
  if (requiredSlots > NOTIFICATION_CAPACITY) {
    warnings.push(`These settings need ${requiredSlots} notification slots for two full 30-minute dose windows, but only ${NOTIFICATION_CAPACITY} are available. The current and next dose cannot both receive full coverage. Choose a repeat interval of at least 2 minutes.`);
  }
  if (snoozeMinutes > PROTECTION_MINUTES) {
    warnings.push('This snooze interval can defer an alert beyond the protected first 30 minutes. Shorten the snooze interval if another alert must occur within that window.');
  }
  return { requiredSlots, warnings };
}
