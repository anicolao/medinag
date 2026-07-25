import { getApp, getApps, initializeApp } from 'firebase/app';
import {
  addDoc,
  collection,
  connectFirestoreEmulator,
  doc,
  getFirestore,
  onSnapshot,
  orderBy,
  query,
  serverTimestamp,
  updateDoc,
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

const STORAGE_KEY = 'medinag:schedules:v1';

function sortSchedules(schedules: MedicationSchedule[]): MedicationSchedule[] {
  return [...schedules].sort((left, right) =>
    left.scheduledTime.localeCompare(right.scheduledTime)
  );
}

class BrowserScheduleRepository implements ScheduleRepository {
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

  private read(): MedicationSchedule[] {
    const stored = localStorage.getItem(STORAGE_KEY);
    if (!stored) {
      return [];
    }
    try {
      return sortSchedules(JSON.parse(stored) as MedicationSchedule[]);
    } catch {
      localStorage.removeItem(STORAGE_KEY);
      return [];
    }
  }

  private write(schedules: MedicationSchedule[]): void {
    const sorted = sortSchedules(schedules);
    localStorage.setItem(STORAGE_KEY, JSON.stringify(sorted));
    for (const listener of this.listeners) {
      listener(sorted);
    }
  }
}

class FirestoreScheduleRepository implements ScheduleRepository {
  readonly mode = 'firestore' as const;

  constructor(private readonly database: Firestore) {}

  subscribe(
    listener: (schedules: MedicationSchedule[]) => void,
    onError?: (error: Error) => void
  ): () => void {
    const schedulesQuery = query(
      collection(this.database, 'schedules'),
      orderBy('scheduledTime')
    );
    return onSnapshot(
      schedulesQuery,
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
    await addDoc(collection(this.database, 'schedules'), {
      ...input,
      createdAt: serverTimestamp(),
      updatedAt: serverTimestamp()
    });
  }

  async update(id: string, input: ScheduleInput): Promise<void> {
    await updateDoc(doc(this.database, 'schedules', id), {
      ...input,
      updatedAt: serverTimestamp()
    });
  }

  async setActive(id: string, active: boolean): Promise<void> {
    await updateDoc(doc(this.database, 'schedules', id), {
      active,
      updatedAt: serverTimestamp()
    });
  }
}

let emulatorConnected = false;

function createFirestore(): Firestore | null {
  const config = {
    apiKey: import.meta.env.VITE_FIREBASE_API_KEY,
    authDomain: import.meta.env.VITE_FIREBASE_AUTH_DOMAIN,
    projectId: import.meta.env.VITE_FIREBASE_PROJECT_ID,
    appId: import.meta.env.VITE_FIREBASE_APP_ID
  };
  if (Object.values(config).some((value) => !value)) {
    return null;
  }

  const app = getApps().length > 0 ? getApp() : initializeApp(config);
  const database = getFirestore(app);
  if (import.meta.env.VITE_USE_FIREBASE_EMULATOR === 'true' && !emulatorConnected) {
    connectFirestoreEmulator(database, '127.0.0.1', 8080);
    emulatorConnected = true;
  }
  return database;
}

export function createScheduleRepository(): ScheduleRepository {
  const database = createFirestore();
  return database
    ? new FirestoreScheduleRepository(database)
    : new BrowserScheduleRepository();
}
