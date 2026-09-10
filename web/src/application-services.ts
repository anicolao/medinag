import {
  getApp,
  getApps,
  initializeApp,
  type FirebaseApp
} from 'firebase/app';
import {
  GoogleAuthProvider,
  connectAuthEmulator,
  getAuth,
  signInWithCredential,
  signInWithPopup,
  type Auth,
  type User
} from 'firebase/auth';
import {
  collection,
  connectFirestoreEmulator,
  doc,
  getDoc,
  getDocs,
  getFirestore,
  serverTimestamp,
  setDoc,
  writeBatch,
  type DocumentData,
  type Firestore
} from 'firebase/firestore';
import type { AdministratorAccount } from './account-types';
import {
  FirestoreAdministratorRepository,
  type AdministratorRepository
} from './administrator-repository';
import {
  FirestoreScheduleRepository,
  type ScheduleRepository
} from './schedule-repository';
import {
  FirestoreTodayRepository,
  type TodayRepository
} from './today-repository';

export interface ApplicationServices {
  account: AdministratorAccount;
  administrator?: AdministratorRepository;
  schedules?: ScheduleRepository;
  today?: TodayRepository;
}

const ACCOUNT_NOTICE_KEY = 'medinag:account-notice';
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

function planCode(user: User): string {
  const prefix = (user.displayName || 'PLAN')
    .replace(/[^a-z0-9]/gi, '')
    .slice(0, 4)
    .toUpperCase()
    .padEnd(4, 'X');
  let hash = 2_166_136_261;
  for (const character of user.email || user.uid) {
    hash ^= character.charCodeAt(0);
    hash = Math.imul(hash, 16_777_619);
  }
  const suffix = (hash >>> 0).toString(36).toUpperCase().padStart(4, '0').slice(-4);
  return `${prefix}-${suffix}`;
}

function cleanLegacyDose(data: DocumentData): DocumentData {
  return {
    medicationName: String(data.medicationName),
    scheduledTime: String(data.scheduledTime),
    daysOfWeek: [...(data.daysOfWeek as number[])],
    active: Boolean(data.active),
    createdAt: data.createdAt,
    updatedAt: serverTimestamp()
  };
}

async function ensureAdministrator(
  database: Firestore,
  user: User
): Promise<number> {
  const reference = doc(database, 'administrators', user.uid);
  const snapshot = await getDoc(reference);
  if (!snapshot.exists()) {
    await setDoc(reference, {
      uid: user.uid,
      displayName: user.displayName || 'Administrator',
      email: user.email || '',
      planName: `${user.displayName || 'My'}'s medication schedule`,
      planCode: planCode(user),
      published: false,
      patientUid: null,
      patientDisplayName: '',
      snoozeIntervalMinutes: 10,
      escalationDeadlineMinutes: 30,
      maxReminders: 3,
      timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone || 'America/Toronto',
      smsNumber: '',
      createdAt: serverTimestamp(),
      updatedAt: serverTimestamp()
    });
  }

  const [anonymousLegacy, householdLegacy] = await Promise.all([
    getDocs(collection(database, 'admins', user.uid, 'schedules')),
    getDocs(collection(database, 'households', user.uid, 'schedules'))
  ]);
  const existing = await getDocs(
    collection(database, 'administrators', user.uid, 'doses')
  );
  const existingIds = new Set(existing.docs.map(({ id }) => id));
  const legacyById = new Map(
    [...anonymousLegacy.docs, ...householdLegacy.docs]
      .filter(({ id }) => !existingIds.has(id))
      .map((dose) => [dose.id, dose] as const)
  );
  const legacy = [...legacyById.values()];
  if (legacy.length === 0) {
    return 0;
  }
  const batch = writeBatch(database);
  for (const dose of legacy) {
    batch.set(
      doc(database, 'administrators', user.uid, 'doses', dose.id),
      cleanLegacyDose(dose.data())
    );
  }
  await batch.commit();
  return legacy.length;
}

function signedOutAccount(auth: Auth, database: Firestore): AdministratorAccount {
  return {
    kind: 'signed-out',
    userId: '',
    displayName: '',
    email: '',
    notice: consumeNotice(),
    async signInWithGoogle(): Promise<void> {
      const provider = new GoogleAuthProvider();
      provider.setCustomParameters({ prompt: 'select_account' });
      const user = (await signInWithPopup(auth, provider)).user;
      const migrated = await ensureAdministrator(database, user);
      reloadWithNotice(
        migrated > 0
          ? `${migrated} existing ${migrated === 1 ? 'dose was' : 'doses were'} preserved in your new plan.`
          : 'Signed in with Google.'
      );
    },
    async signOut(): Promise<void> {
      return undefined;
    }
  };
}

function googleAccount(auth: Auth, user: User, notice: string): AdministratorAccount {
  return {
    kind: 'google',
    userId: user.uid,
    displayName: user.displayName || 'Administrator',
    email: user.email || '',
    notice,
    async signInWithGoogle(): Promise<void> {
      return undefined;
    },
    async signOut(): Promise<void> {
      await auth.signOut();
      window.location.hash = '';
      window.location.reload();
    }
  };
}

function unavailableAccount(): AdministratorAccount {
  return {
    kind: 'unavailable',
    userId: '',
    displayName: '',
    email: '',
    notice: '',
    async signInWithGoogle(): Promise<void> {
      throw new Error('Firebase configuration is required for Google Sign-In.');
    },
    async signOut(): Promise<void> {
      return undefined;
    }
  };
}

async function emulatorGoogleUser(auth: Auth): Promise<User | null> {
  if (import.meta.env.VITE_USE_FIREBASE_EMULATOR !== 'true') {
    return null;
  }
  const encoded = import.meta.env.VITE_FIREBASE_EMULATOR_GOOGLE_ID_TOKEN_BASE64;
  if (!encoded) {
    return null;
  }
  const token = new TextDecoder().decode(
    Uint8Array.from(atob(encoded), (character) => character.charCodeAt(0))
  );
  return (await signInWithCredential(
    auth,
    GoogleAuthProvider.credential(token)
  )).user;
}

export async function createApplicationServices(): Promise<ApplicationServices> {
  const firebase = createFirebase();
  if (!firebase) {
    return { account: unavailableAccount() };
  }

  await firebase.auth.authStateReady();
  let user = firebase.auth.currentUser;
  user ??= await emulatorGoogleUser(firebase.auth);
  if (!user) {
    return { account: signedOutAccount(firebase.auth, firebase.database) };
  }

  const migrated = await ensureAdministrator(firebase.database, user);
  const notice = migrated > 0
    ? `${migrated} existing ${migrated === 1 ? 'dose was' : 'doses were'} preserved in your new plan.`
    : consumeNotice();
  return {
    account: googleAccount(firebase.auth, user, notice),
    administrator: new FirestoreAdministratorRepository(firebase.database, user.uid),
    schedules: new FirestoreScheduleRepository(
      firebase.database,
      ['administrators', user.uid, 'doses'],
      ['administrators', user.uid, 'medicationEvents']
    ),
    today: new FirestoreTodayRepository(firebase.database, user.uid)
  };
}
