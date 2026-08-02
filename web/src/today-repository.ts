import {
  collection,
  onSnapshot,
  orderBy,
  query,
  type Firestore,
  type Timestamp
} from 'firebase/firestore';
import type { MedicationEvent, MedicationEventStatus } from './medication-event-types';

export interface TodayRepository {
  readonly mode: 'firestore' | 'preview';
  subscribe(
    listener: (events: MedicationEvent[]) => void,
    onError?: (error: Error) => void
  ): () => void;
}

export const EVENT_STORAGE_KEY = 'medinag:events:v1';

function parseDate(value: unknown): Date {
  if (value && typeof value === 'object' && 'toDate' in value) {
    return (value as Timestamp).toDate();
  }
  return new Date(String(value));
}

export class BrowserTodayRepository implements TodayRepository {
  readonly mode = 'preview' as const;

  subscribe(listener: (events: MedicationEvent[]) => void): () => void {
    const stored = localStorage.getItem(EVENT_STORAGE_KEY);
    if (!stored) {
      listener([]);
      return () => undefined;
    }
    try {
      const values = JSON.parse(stored) as Array<
        Omit<MedicationEvent, 'scheduledTime' | 'completedAt'> & {
          scheduledTime: string;
          completedAt: string | null;
        }
      >;
      listener(
        values.map((event) => ({
          ...event,
          scheduledTime: new Date(event.scheduledTime),
          completedAt: event.completedAt ? new Date(event.completedAt) : null
        }))
      );
    } catch {
      localStorage.removeItem(EVENT_STORAGE_KEY);
      listener([]);
    }
    return () => undefined;
  }
}

export class FirestoreTodayRepository implements TodayRepository {
  readonly mode = 'firestore' as const;

  constructor(
    private readonly database: Firestore,
    private readonly householdId: string
  ) {}

  subscribe(
    listener: (events: MedicationEvent[]) => void,
    onError?: (error: Error) => void
  ): () => void {
    const events = query(
      collection(
        this.database,
        'households',
        this.householdId,
        'medicationEvents'
      ),
      orderBy('scheduledTime')
    );
    return onSnapshot(
      events,
      (snapshot) => {
        listener(
          snapshot.docs.map((event) => ({
            id: event.id,
            medicationName: String(event.data().medicationName),
            scheduledTime: parseDate(event.data().scheduledTime),
            status: String(event.data().status) as MedicationEventStatus,
            snoozeCount: Number(event.data().snoozeCount),
            completedAt: event.data().completedAt
              ? parseDate(event.data().completedAt)
              : null
          }))
        );
      },
      (error) => onError?.(error)
    );
  }
}
