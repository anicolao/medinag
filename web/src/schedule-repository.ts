import {
  collection,
  doc,
  getDocs,
  onSnapshot,
  orderBy,
  query,
  serverTimestamp,
  Timestamp,
  where,
  writeBatch,
  type CollectionReference,
  type Firestore
} from 'firebase/firestore';
import type { MedicationSchedule, ScheduleInput } from './schedule-types';

export interface ScheduleRepository {
  readonly mode: 'firestore' | 'preview';
  subscribe(
    listener: (schedules: MedicationSchedule[]) => void,
    onError?: (error: Error) => void
  ): () => void;
  create(input: ScheduleInput): Promise<void>;
  update(id: string, input: ScheduleInput): Promise<void>;
  setActive(id: string, active: boolean): Promise<void>;
}

export const SCHEDULE_STORAGE_KEY = 'medinag:schedules:v1';

function sortSchedules(schedules: MedicationSchedule[]): MedicationSchedule[] {
  return [...schedules].sort((left, right) =>
    left.scheduledTime.localeCompare(right.scheduledTime)
  );
}

export class BrowserScheduleRepository implements ScheduleRepository {
  readonly mode = 'preview' as const;
  private readonly listeners = new Set<(schedules: MedicationSchedule[]) => void>();

  subscribe(listener: (schedules: MedicationSchedule[]) => void): () => void {
    this.listeners.add(listener);
    listener(this.read());
    return () => this.listeners.delete(listener);
  }

  async create(input: ScheduleInput): Promise<void> {
    const id = `schedule-${crypto.randomUUID()}`;
    this.write([...this.read(), { id, ...input }]);
  }

  async update(id: string, input: ScheduleInput): Promise<void> {
    this.write(
      this.read().map((schedule) =>
        schedule.id === id ? { id, ...input } : schedule
      )
    );
  }

  async setActive(id: string, active: boolean): Promise<void> {
    this.write(
      this.read().map((schedule) =>
        schedule.id === id ? { ...schedule, active } : schedule
      )
    );
  }

  read(): MedicationSchedule[] {
    const stored = localStorage.getItem(SCHEDULE_STORAGE_KEY);
    if (!stored) {
      return [];
    }
    try {
      return sortSchedules(JSON.parse(stored) as MedicationSchedule[]);
    } catch {
      localStorage.removeItem(SCHEDULE_STORAGE_KEY);
      return [];
    }
  }

  private write(schedules: MedicationSchedule[]): void {
    const sorted = sortSchedules(schedules);
    localStorage.setItem(SCHEDULE_STORAGE_KEY, JSON.stringify(sorted));
    for (const listener of this.listeners) {
      listener(sorted);
    }
  }
}

export class FirestoreScheduleRepository implements ScheduleRepository {
  readonly mode = 'firestore' as const;
  private readonly schedules: CollectionReference;
  private readonly medicationEvents?: CollectionReference;

  constructor(
    private readonly database: Firestore,
    path: string[],
    householdId?: string
  ) {
    this.schedules = collection(database, path.join('/'));
    this.medicationEvents = householdId
      ? collection(database, 'households', householdId, 'medicationEvents')
      : undefined;
  }

  subscribe(
    listener: (schedules: MedicationSchedule[]) => void,
    onError?: (error: Error) => void
  ): () => void {
    return onSnapshot(
      query(this.schedules, orderBy('scheduledTime')),
      (snapshot) => {
        listener(
          snapshot.docs.map((schedule) => ({
            id: schedule.id,
            medicationName: String(schedule.data().medicationName),
            scheduledTime: String(schedule.data().scheduledTime),
            daysOfWeek: [...(schedule.data().daysOfWeek as number[])],
            active: Boolean(schedule.data().active)
          }))
        );
      },
      (error) => onError?.(error)
    );
  }

  async create(input: ScheduleInput): Promise<void> {
    const schedule = doc(this.schedules);
    const batch = writeBatch(this.database);
    batch.set(schedule, {
      ...input,
      createdAt: serverTimestamp(),
      updatedAt: serverTimestamp()
    });
    if (this.medicationEvents && input.active) {
      batch.set(doc(this.medicationEvents), medicationEvent(schedule.id, input));
    }
    await batch.commit();
  }

  async update(id: string, input: ScheduleInput): Promise<void> {
    const batch = writeBatch(this.database);
    batch.update(doc(this.schedules, id), {
      ...input,
      updatedAt: serverTimestamp()
    });
    if (this.medicationEvents && input.active) {
      const existingEvents = await getDocs(
        query(this.medicationEvents, where('scheduleId', '==', id))
      );
      const unfinishedEvents = existingEvents.docs.filter(
        (event) => event.data().status !== 'completed'
      );
      if (unfinishedEvents.length === 0) {
        batch.set(doc(this.medicationEvents), medicationEvent(id, input));
      } else {
        for (const event of unfinishedEvents) {
          batch.update(event.ref, {
            medicationName: input.medicationName,
            scheduledTime: Timestamp.fromDate(nextOccurrence(input)),
            updatedAt: serverTimestamp()
          });
        }
      }
    }
    await batch.commit();
  }

  async setActive(id: string, active: boolean): Promise<void> {
    const batch = writeBatch(this.database);
    batch.update(doc(this.schedules, id), {
      active,
      updatedAt: serverTimestamp()
    });
    await batch.commit();
  }
}

function medicationEvent(
  scheduleId: string,
  input: ScheduleInput
): Record<string, unknown> {
  return {
    scheduleId,
    medicationName: input.medicationName,
    scheduledTime: Timestamp.fromDate(nextOccurrence(input)),
    status: 'pending',
    snoozeCount: 0,
    lastSnoozedAt: null,
    completedAt: null,
    createdAt: serverTimestamp(),
    updatedAt: serverTimestamp()
  };
}

export function nextOccurrence(input: ScheduleInput, now = new Date()): Date {
  const [hour, minute] = input.scheduledTime.split(':').map(Number);
  for (let dayOffset = 0; dayOffset <= 7; dayOffset += 1) {
    const candidate = new Date(now);
    candidate.setDate(now.getDate() + dayOffset);
    candidate.setHours(hour, minute, 0, 0);
    const mondayBasedDay = ((candidate.getDay() + 6) % 7) + 1;
    if (input.daysOfWeek.includes(mondayBasedDay) && candidate > now) {
      return candidate;
    }
  }
  throw new Error('The schedule has no future occurrence.');
}
