import {
  doc,
  onSnapshot,
  serverTimestamp,
  updateDoc,
  type Firestore
} from 'firebase/firestore';
import type {
  AdministratorProfile,
  AdministratorSettingsInput
} from './administrator-types';

export interface AdministratorRepository {
  subscribe(
    listener: (profile: AdministratorProfile) => void,
    onError?: (error: Error) => void
  ): () => void;
  updateSettings(input: AdministratorSettingsInput): Promise<void>;
  publish(): Promise<void>;
  disconnectPatient(): Promise<void>;
}

export class FirestoreAdministratorRepository
implements AdministratorRepository {
  constructor(
    private readonly database: Firestore,
    private readonly administratorId: string
  ) {}

  subscribe(
    listener: (profile: AdministratorProfile) => void,
    onError?: (error: Error) => void
  ): () => void {
    return onSnapshot(
      doc(this.database, 'administrators', this.administratorId),
      (snapshot) => {
        const data = snapshot.data();
        if (!data) {
          onError?.(new Error('The administrator profile is unavailable.'));
          return;
        }
        listener({
          uid: snapshot.id,
          displayName: String(data.displayName),
          email: String(data.email),
          planName: String(data.planName),
          planCode: String(data.planCode),
          published: Boolean(data.published),
          patientUid: typeof data.patientUid === 'string' ? data.patientUid : null,
          patientDisplayName: String(data.patientDisplayName ?? ''),
          snoozeIntervalMinutes: Number(data.snoozeIntervalMinutes),
          escalationDeadlineMinutes: Number(data.escalationDeadlineMinutes),
          maxReminders: Number(data.maxReminders),
          timeZone: String(data.timeZone),
          smsNumber: String(data.smsNumber)
        });
      },
      (error) => onError?.(error)
    );
  }

  async updateSettings(input: AdministratorSettingsInput): Promise<void> {
    await updateDoc(doc(this.database, 'administrators', this.administratorId), {
      ...input,
      updatedAt: serverTimestamp()
    });
  }

  async publish(): Promise<void> {
    await updateDoc(doc(this.database, 'administrators', this.administratorId), {
      published: true,
      publishedAt: serverTimestamp(),
      updatedAt: serverTimestamp()
    });
  }

  async disconnectPatient(): Promise<void> {
    await updateDoc(doc(this.database, 'administrators', this.administratorId), {
      patientUid: null,
      patientDisplayName: '',
      updatedAt: serverTimestamp()
    });
  }
}
