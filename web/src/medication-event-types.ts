export type MedicationEventStatus = 'pending' | 'snoozed' | 'completed';

export interface MedicationEvent {
  id: string;
  medicationName: string;
  occurrenceDate: string;
  scheduledLocalTime: string;
  timeZone: string;
  scheduledTime: Date;
  status: MedicationEventStatus;
  snoozeCount: number;
  completedAt: Date | null;
}
