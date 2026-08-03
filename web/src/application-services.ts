import {
  FirebaseError,
  getApp,
  getApps,
  initializeApp,
  type FirebaseApp
} from 'firebase/app';
import {
  GoogleAuthProvider,
  connectAuthEmulator,
  getAuth,
  linkWithPopup,
  signInAnonymously,
  signInWithCredential,
  type Auth,
  type AuthError,
  type User
} from 'firebase/auth';
import {
  connectFirestoreEmulator,
  collection,
  doc,
  getDoc,
  getDocs,
  getFirestore,
  serverTimestamp,
  setDoc,
  updateDoc,
  type DocumentData,
  type Firestore
} from 'firebase/firestore';
import type { AdvisorAccount } from './account-types';
import {
  BrowserScheduleRepository,
  FirestoreScheduleRepository,
  type ScheduleRepository
} from './schedule-repository';
import {
  BrowserTodayRepository,
  FirestoreTodayRepository,
  type TodayRepository
} from './today-repository';

interface LegacySchedule {
  id: string;
  data: DocumentData;
}

export interface ApplicationServices {
  account: AdvisorAccount;
  schedules: ScheduleRepository;
  today: TodayRepository;
}

const ACCOUNT_NOTICE_KEY = 'medinag:account-notice';
const E2E_LINKED_KEY = 'medinag:e2e-google-linked';
let emulatorsConnected = false;

function consumeNotice(): string {
  const notice = sessionStorage.getItem(ACCOUNT_NOTICE_KEY) ?? '';
  sessionStorage.removeItem(ACCOUNT_NOTICE_KEY);
  return notice;
}

function reloadWithNotice(notice: string): void {
  sessionStorage.setItem(ACCOUNT_NOTICE_KEY, notice);
  window.location.reload();
}

function createFirebase(): { app: FirebaseApp; auth: Auth; database: Firestore } | null {
  const config = {
    apiKey: import.meta.env.VITE_FIREBASE_API_KEY,
    authDomain: import.meta.env.VITE_FIREBASE_AUTH_DOMAIN,
    projectId: import.meta.env.VITE_FIREBASE_PROJECT_ID,
    storageBucket: import.meta.env.VITE_FIREBASE_STORAGE_BUCKET,
    messagingSenderId: import.meta.env.VITE_FIREBASE_MESSAGING_SENDER_ID,
    appId: import.meta.env.VITE_FIREBASE_APP_ID
  };
  if (Object.values(config).some((value) => !value)) {
    return null;
  }

  const app = getApps().length > 0 ? getApp() : initializeApp(config);
  const auth = getAuth(app);
  const database = getFirestore(app);
  if (import.meta.env.VITE_USE_FIREBASE_EMULATOR === 'true' && !emulatorsConnected) {
    connectAuthEmulator(auth, 'http://127.0.0.1:9099', {
      disableWarnings: true
    });
    connectFirestoreEmulator(database, '127.0.0.1', 8080);
    emulatorsConnected = true;
  }
  return { app, auth, database };
}

function isGoogleUser(user: User): boolean {
  return user.providerData.some(({ providerId }) => providerId === 'google.com');
}

async function readLegacySchedules(
  database: Firestore,
  userId: string
): Promise<LegacySchedule[]> {
  const snapshot = await getDocs(
    collection(database, 'admins', userId, 'schedules')
  );
  return snapshot.docs.map((schedule) => ({
    id: schedule.id,
    data: schedule.data()
  }));
}

function sanitizedSchedule(data: DocumentData): DocumentData {
  return {
    medicationName: String(data.medicationName),
    scheduledTime: String(data.scheduledTime),
    daysOfWeek: [...(data.daysOfWeek as number[])],
    active: Boolean(data.active),
    createdAt: data.createdAt,
    updatedAt: data.updatedAt
  };
}

async function ensureHousehold(
  database: Firestore,
  user: User,
  legacySchedules: LegacySchedule[]
): Promise<number> {
  const householdId = user.uid;
  const householdReference = doc(database, 'households', householdId);
  const householdSnapshot = await getDoc(householdReference);
  if (!householdSnapshot.exists()) {
    await setDoc(householdReference, {
      advisorUid: user.uid,
      name: `${user.displayName?.split(' ')[0] || 'Lori'}'s household`,
      subjectName: 'Steve',
      migrationVersion: 0,
      createdAt: serverTimestamp(),
      updatedAt: serverTimestamp()
    });
  }

  const memberReference = doc(
    database,
    'households',
    householdId,
    'members',
    user.uid
  );
  const memberSnapshot = await getDoc(memberReference);
  if (!memberSnapshot.exists()) {
    await setDoc(memberReference, {
      uid: user.uid,
      role: 'advisor',
      displayName: user.displayName || 'Lori',
      email: user.email || '',
      createdAt: serverTimestamp(),
      updatedAt: serverTimestamp()
    });
  }

  let migratedCount = 0;
  for (const legacy of legacySchedules) {
    const target = doc(
      database,
      'households',
      householdId,
      'schedules',
      legacy.id
    );
    if (!(await getDoc(target)).exists()) {
      await setDoc(target, sanitizedSchedule(legacy.data));
      migratedCount += 1;
    }
  }

  await updateDoc(householdReference, {
    migrationVersion: 1,
    updatedAt: serverTimestamp()
  });
  return migratedCount;
}

function browserServices(): ApplicationServices {
  const schedules = new BrowserScheduleRepository();
  const e2eLinking = Boolean(window.__MEDINAG_E2E_ACCOUNT_LINK__);
  const linked = localStorage.getItem(E2E_LINKED_KEY) === 'true';
  const account: AdvisorAccount = {
    kind: e2eLinking ? (linked ? 'google' : 'anonymous') : 'preview',
    displayName: linked ? 'Lori Medina' : 'Lori',
    email: linked ? 'lori@gmail.com' : '',
    notice: consumeNotice(),
    async linkGoogle(): Promise<void> {
      if (!e2eLinking) {
        throw new Error('Google linking requires Firebase configuration.');
      }
      localStorage.setItem(E2E_LINKED_KEY, 'true');
      const count = schedules.read().length;
      reloadWithNotice(
        `Google account linked. ${count} existing ${count === 1 ? 'schedule was' : 'schedules were'} moved safely.`
      );
    }
  };
  return {
    account,
    schedules,
    today: new BrowserTodayRepository()
  };
}

function linkedAccount(
  user: User,
  notice: string
): AdvisorAccount {
  return {
    kind: 'google',
    displayName: user.displayName || 'Lori',
    email: user.email || '',
    notice,
    async linkGoogle(): Promise<void> {
      return undefined;
    }
  };
}

function migrationErrorAccount(
  database: Firestore,
  user: User,
  legacySchedules: LegacySchedule[],
  notice: string
): AdvisorAccount {
  return {
    kind: 'migration-error',
    displayName: user.displayName || 'Lori',
    email: user.email || '',
    notice,
    async linkGoogle(): Promise<void> {
      const count = await ensureHousehold(database, user, legacySchedules);
      reloadWithNotice(
        `Migration complete. ${count} existing ${count === 1 ? 'schedule was' : 'schedules were'} moved safely.`
      );
    }
  };
}

function anonymousAccount(
  auth: Auth,
  database: Firestore,
  user: User,
  legacySchedules: LegacySchedule[],
  notice: string
): AdvisorAccount {
  return {
    kind: 'anonymous',
    displayName: 'Lori',
    email: '',
    notice,
    async linkGoogle(): Promise<void> {
      const provider = new GoogleAuthProvider();
      provider.setCustomParameters({ prompt: 'select_account' });
      let linkedUser: User;
      try {
        linkedUser = (await linkWithPopup(user, provider)).user;
      } catch (error) {
        const credential = GoogleAuthProvider.credentialFromError(error as AuthError);
        if (
          error instanceof FirebaseError
          && error.code === 'auth/credential-already-in-use'
          && credential
        ) {
          linkedUser = (await signInWithCredential(auth, credential)).user;
        } else {
          throw error;
        }
      }

      try {
        const count = await ensureHousehold(database, linkedUser, legacySchedules);
        reloadWithNotice(
          `Google account linked. ${count} existing ${count === 1 ? 'schedule was' : 'schedules were'} moved safely.`
        );
      } catch {
        reloadWithNotice(
          'Google account linked. Your existing schedules are safe, but migration needs another attempt.'
        );
      }
    }
  };
}

export async function createApplicationServices(): Promise<ApplicationServices> {
  const firebase = createFirebase();
  if (!firebase) {
    return browserServices();
  }

  await firebase.auth.authStateReady();
  const user = firebase.auth.currentUser
    ?? (await signInAnonymously(firebase.auth)).user;
  const legacySchedules = await readLegacySchedules(firebase.database, user.uid);
  const notice = consumeNotice();

  if (!isGoogleUser(user)) {
    return {
      account: anonymousAccount(
        firebase.auth,
        firebase.database,
        user,
        legacySchedules,
        notice
      ),
      schedules: new FirestoreScheduleRepository(firebase.database, [
        'admins',
        user.uid,
        'schedules'
      ]),
      today: new BrowserTodayRepository()
    };
  }

  let migratedCount: number;
  try {
    migratedCount = await ensureHousehold(
      firebase.database,
      user,
      legacySchedules
    );
  } catch {
    return {
      account: migrationErrorAccount(
        firebase.database,
        user,
        legacySchedules,
        notice || 'Google is linked, but the household migration needs another attempt.'
      ),
      schedules: new FirestoreScheduleRepository(firebase.database, [
        'admins',
        user.uid,
        'schedules'
      ]),
      today: new BrowserTodayRepository()
    };
  }
  const migrationNotice = migratedCount > 0
    ? `${migratedCount} existing ${migratedCount === 1 ? 'schedule was' : 'schedules were'} moved safely.`
    : notice;
  return {
    account: linkedAccount(
      user,
      migrationNotice
    ),
    schedules: new FirestoreScheduleRepository(firebase.database, [
      'households',
      user.uid,
      'schedules'
    ]),
    today: new FirestoreTodayRepository(firebase.database, user.uid)
  };
}
