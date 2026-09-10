export interface AdministratorProfile {
  uid: string;
  displayName: string;
  email: string;
  planName: string;
  planCode: string;
  published: boolean;
  patientUid: string | null;
  patientDisplayName: string;
  snoozeIntervalMinutes: number;
  escalationDeadlineMinutes: number;
  maxReminders: number;
  timeZone: string;
  smsNumber: string;
}

export interface AdministratorSettingsInput {
  displayName: string;
  planName: string;
  snoozeIntervalMinutes: number;
  escalationDeadlineMinutes: number;
  maxReminders: number;
  timeZone: string;
  smsNumber: string;
}
