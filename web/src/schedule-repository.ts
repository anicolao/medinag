import {
  addDoc,
  collection,
  doc,
  onSnapshot,
  orderBy,
  query,
  serverTimestamp,
  updateDoc,
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
  private sequence = 0;

  subscribe(listener: (schedules: MedicationSchedule[]) => void): () => void {
    this.listeners.add(listener);
    listener(this.read());
    return () => this.listeners.delete(listener);
  }

  async create(input: ScheduleInput): Promise<void> {
    const id = window.__MEDINAG_E2E__
      ? `e2e-schedule-${this.sequence++}`
      : `schedule-${crypto.randomUUID()}`;
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

  constructor(database: Firestore, path: string[]) {
    this.schedules = collection(database, path.join('/'));
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
    await addDoc(this.schedules, {
      ...input,
      createdAt: serverTimestamp(),
      updatedAt: serverTimestamp()
    });
  }

  async update(id: string, input: ScheduleInput): Promise<void> {
    await updateDoc(doc(this.schedules, id), {
      ...input,
      updatedAt: serverTimestamp()
    });
  }

  async setActive(id: string, active: boolean): Promise<void> {
    await updateDoc(doc(this.schedules, id), {
      active,
      updatedAt: serverTimestamp()
    });
  }
}
