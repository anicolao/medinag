export type MedicationEventStatus = 'pending' | 'snoozed' | 'completed';

export interface MedicationEvent {
  id: string;
  medicationName: string;
  scheduledTime: Date;
  status: MedicationEventStatus;
  snoozeCount: number;
  completedAt: Date | null;
}
