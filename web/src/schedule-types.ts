export const DAYS = [
  { value: 1, short: 'Mon', long: 'Monday' },
  { value: 2, short: 'Tue', long: 'Tuesday' },
  { value: 3, short: 'Wed', long: 'Wednesday' },
  { value: 4, short: 'Thu', long: 'Thursday' },
  { value: 5, short: 'Fri', long: 'Friday' },
  { value: 6, short: 'Sat', long: 'Saturday' },
  { value: 7, short: 'Sun', long: 'Sunday' }
] as const;

export interface MedicationSchedule {
  id: string;
  medicationName: string;
  scheduledTime: string;
  daysOfWeek: number[];
  active: boolean;
}

export type ScheduleInput = Omit<MedicationSchedule, 'id'>;

export function describeDays(days: number[]): string {
  const normalized = [...days].sort((left, right) => left - right);
  if (normalized.length === 7) {
    return 'Every day';
  }
  if (normalized.join(',') === '1,2,3,4,5') {
    return 'Weekdays';
  }
  if (normalized.join(',') === '6,7') {
    return 'Weekends';
  }
  return normalized
    .map((day) => DAYS.find(({ value }) => value === day)?.short)
    .filter(Boolean)
    .join(', ');
}

export function formatTime(time: string): string {
  const [hourText, minute] = time.split(':');
  const hour = Number(hourText);
  const suffix = hour >= 12 ? 'PM' : 'AM';
  const displayHour = hour % 12 || 12;
  return `${displayHour}:${minute} ${suffix}`;
}
