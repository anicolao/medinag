import { DateTime } from 'luxon';

export interface DoseDefinition {
  id: string;
  medicationName: string;
  scheduledTime: string;
  daysOfWeek: number[];
  active: boolean;
}

export interface OccurrenceDefinition {
  id: string;
  scheduleId: string;
  medicationName: string;
  occurrenceDate: string;
  scheduledLocalTime: string;
  timeZone: string;
  scheduledTime: Date;
}

const localTimePattern = /^([01]\d|2[0-3]):([0-5]\d)$/;

export function buildOccurrences(
  dose: DoseDefinition,
  patientTimeZone: string,
  now: Date,
  horizonDays = 7
): OccurrenceDefinition[] {
  if (!dose.active) return [];
  const match = localTimePattern.exec(dose.scheduledTime);
  if (!match) throw new Error(`Invalid scheduled time: ${dose.scheduledTime}`);
  if (!DateTime.local().setZone(patientTimeZone).isValid) {
    throw new Error(`Invalid patient time zone: ${patientTimeZone}`);
  }
  const hour = Number(match[1]);
  const minute = Number(match[2]);
  const localNow = DateTime.fromJSDate(now, { zone: patientTimeZone });
  const occurrences: OccurrenceDefinition[] = [];

  for (let offset = 0; offset < horizonDays; offset += 1) {
    const date = localNow.startOf('day').plus({ days: offset });
    if (!dose.daysOfWeek.includes(date.weekday)) continue;
    const scheduled = date.set({ hour, minute, second: 0, millisecond: 0 });
    if (!scheduled.isValid) {
      throw new Error(
        `Medication time ${dose.scheduledTime} does not exist on ${date.toISODate()} in ${patientTimeZone}`
      );
    }
    if (scheduled.toMillis() <= now.getTime()) continue;
    const occurrenceDate = scheduled.toISODate();
    if (!occurrenceDate) throw new Error('Could not resolve occurrence date.');
    occurrences.push({
      id: `${dose.id}_${occurrenceDate.replaceAll('-', '')}`,
      scheduleId: dose.id,
      medicationName: dose.medicationName,
      occurrenceDate,
      scheduledLocalTime: dose.scheduledTime,
      timeZone: patientTimeZone,
      scheduledTime: scheduled.toUTC().toJSDate()
    });
  }
  return occurrences;
}
