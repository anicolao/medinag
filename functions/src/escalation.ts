export interface EscalationOperations {
  ensureAdministratorIncident: () => Promise<void>;
  markMedicationEventEscalated: () => Promise<void>;
}

export function escalationIncidentId(eventId: string): string {
  return `unanswered-dose-${eventId}`;
}

export function isMedicationEventOverdue(
  scheduledTime: Date,
  escalationDeadlineMinutes: number,
  now: Date
): boolean {
  return scheduledTime.getTime() + escalationDeadlineMinutes * 60_000 <= now.getTime();
}

export function isMedicationEventSuperseded(
  scheduledTime: Date,
  latestScheduledTime: Date | undefined,
  now: Date
): boolean {
  return latestScheduledTime !== undefined
    && latestScheduledTime.getTime() > scheduledTime.getTime()
    && latestScheduledTime.getTime() <= now.getTime();
}

/**
 * Preserve the safety invariant that an event never claims to be escalated
 * unless the corresponding administrator incident already exists.
 */
export async function escalateMedicationEvent(
  operations: EscalationOperations
): Promise<void> {
  await operations.ensureAdministratorIncident();
  await operations.markMedicationEventEscalated();
}
