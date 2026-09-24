import {
  collection,
  onSnapshot,
  type Firestore,
  type Timestamp
} from 'firebase/firestore';

export interface DeviceCoverage {
  id: string;
  patientUid: string;
  timeZone: string;
  lastRefreshAt: Date;
  scheduledThrough: Date;
  reconciliationStatus: 'ready' | 'failed';
  expectedPendingCount: number;
  actualPendingCount: number;
}

export interface SystemIncident {
  id: string;
  code: string;
  message: string;
  severity: 'warning' | 'critical';
  status: 'open' | 'resolved';
  lastOccurredAt: Date;
  occurrenceCount: number;
  smsState: string;
  smsAttempts: number;
  smsProviderMessageId: string;
}

export interface SystemHealthSnapshot {
  coverage: DeviceCoverage[];
  incidents: SystemIncident[];
}

export interface SystemHealthRepository {
  subscribe(
    listener: (snapshot: SystemHealthSnapshot) => void,
    onError?: (error: Error) => void
  ): () => void;
}

function asDate(value: unknown): Date {
  return value && typeof value === 'object' && 'toDate' in value
    ? (value as Timestamp).toDate()
    : new Date(String(value));
}

export class FirestoreSystemHealthRepository implements SystemHealthRepository {
  constructor(
    private readonly database: Firestore,
    private readonly administratorId: string
  ) {}

  subscribe(
    listener: (snapshot: SystemHealthSnapshot) => void,
    onError?: (error: Error) => void
  ): () => void {
    let coverage: DeviceCoverage[] = [];
    let incidents: SystemIncident[] = [];
    const emit = (): void => listener({ coverage, incidents });
    const unsubscribeCoverage = onSnapshot(
      collection(
        this.database,
        'administrators',
        this.administratorId,
        'deviceCoverage'
      ),
      (snapshot) => {
        coverage = snapshot.docs.map((document) => ({
          id: document.id,
          patientUid: String(document.data().patientUid),
          timeZone: String(document.data().timeZone),
          lastRefreshAt: asDate(document.data().lastRefreshAt),
          scheduledThrough: asDate(document.data().scheduledThrough),
          reconciliationStatus: document.data().reconciliationStatus === 'ready'
            ? 'ready'
            : 'failed',
          expectedPendingCount: Number(document.data().expectedPendingCount),
          actualPendingCount: Number(document.data().actualPendingCount)
        }));
        emit();
      },
      (error) => onError?.(error)
    );
    const unsubscribeIncidents = onSnapshot(
      collection(
        this.database,
        'administrators',
        this.administratorId,
        'systemIncidents'
      ),
      (snapshot) => {
        incidents = snapshot.docs.map((document) => ({
          id: document.id,
          code: String(document.data().code),
          message: String(document.data().message),
          severity: document.data().severity === 'critical' ? 'critical' : 'warning',
          status: document.data().status === 'resolved' ? 'resolved' : 'open',
          lastOccurredAt: asDate(document.data().lastOccurredAt),
          occurrenceCount: Number(document.data().occurrenceCount),
          smsState: String(document.data().smsState ?? 'not_requested'),
          smsAttempts: Number(document.data().smsAttempts ?? 0),
          smsProviderMessageId: String(document.data().smsProviderMessageId ?? '')
        }));
        emit();
      },
      (error) => onError?.(error)
    );
    return () => {
      unsubscribeCoverage();
      unsubscribeIncidents();
    };
  }
}
