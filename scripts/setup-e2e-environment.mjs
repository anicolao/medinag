import { randomBytes, randomInt, randomUUID } from 'node:crypto';
import { chmod, writeFile } from 'node:fs/promises';
import { deleteApp, initializeApp } from 'firebase/app';
import {
  connectAuthEmulator,
  createUserWithEmailAndPassword,
  getAuth
} from 'firebase/auth';
import {
  connectFirestoreEmulator,
  doc,
  getFirestore,
  serverTimestamp,
  setDoc
} from 'firebase/firestore';

const required = (name) => {
  const value = process.env[name];
  if (!value) {
    throw new Error(`${name} is required.`);
  }
  return value;
};

const projectId = required('MEDINAG_E2E_PROJECT_ID');
const authHost = required('MEDINAG_E2E_AUTH_HOST');
const firestoreHost = required('MEDINAG_E2E_FIRESTORE_HOST');
const advisorName = required('MEDINAG_E2E_ADVISOR_NAME');
const subjectName = required('MEDINAG_E2E_SUBJECT_NAME');
const stateFile = required('MEDINAG_E2E_STATE_FILE');
const authMode = process.env.MEDINAG_E2E_AUTH_MODE ?? 'advisor';
if (!['advisor', 'anonymous'].includes(authMode)) {
  throw new Error('MEDINAG_E2E_AUTH_MODE must be advisor or anonymous.');
}
const runId = randomUUID();
const password = randomBytes(24).toString('base64url');
const messagingSenderId = String(randomInt(100_000_000_000, 999_999_999_999));
const firebaseConfig = {
  apiKey: `AIzaSy${randomBytes(25).toString('base64url')}`,
  authDomain: `${projectId}.firebaseapp.com`,
  projectId,
  storageBucket: `${projectId}.appspot.com`,
  messagingSenderId,
  appId: `1:${messagingSenderId}:ios:${randomBytes(16).toString('hex')}`
};

const advisorApp = initializeApp(firebaseConfig, `advisor-${runId}`);
const advisorAuth = getAuth(advisorApp);
connectAuthEmulator(advisorAuth, `http://${authHost}`, { disableWarnings: true });
const advisorDatabase = getFirestore(advisorApp);
const [firestoreHostname, firestorePort] = firestoreHost.split(':');
connectFirestoreEmulator(
  advisorDatabase,
  firestoreHostname,
  Number(firestorePort)
);

const advisorEmail = `advisor-${runId}@medinag.invalid`;
const advisor = await createUserWithEmailAndPassword(
  advisorAuth,
  advisorEmail,
  password
);
const householdId = advisor.user.uid;

await setDoc(doc(advisorDatabase, 'households', householdId), {
  advisorUid: advisor.user.uid,
  name: `${advisorName}'s household`,
  subjectName,
  migrationVersion: 1,
  createdAt: serverTimestamp(),
  updatedAt: serverTimestamp()
});
await setDoc(
  doc(advisorDatabase, 'households', householdId, 'members', advisor.user.uid),
  {
    uid: advisor.user.uid,
    role: 'advisor',
    displayName: advisorName,
    email: advisorEmail,
    createdAt: serverTimestamp(),
    updatedAt: serverTimestamp()
  }
);

const subjectApp = initializeApp(firebaseConfig, `subject-${runId}`);
const subjectAuth = getAuth(subjectApp);
connectAuthEmulator(subjectAuth, `http://${authHost}`, { disableWarnings: true });
const subjectEmail = `subject-${runId}@medinag.invalid`;
const subject = await createUserWithEmailAndPassword(
  subjectAuth,
  subjectEmail,
  password
);

await setDoc(
  doc(advisorDatabase, 'households', householdId, 'members', subject.user.uid),
  {
    uid: subject.user.uid,
    role: 'subject',
    displayName: subjectName,
    email: subjectEmail,
    createdAt: serverTimestamp(),
    updatedAt: serverTimestamp()
  }
);

const state = {
  runId,
  firebase: firebaseConfig,
  emulators: { authHost, firestoreHost },
  householdId,
  advisor: { uid: advisor.user.uid, email: advisorEmail, password },
  subject: { uid: subject.user.uid, email: subjectEmail, password }
};
await writeFile(stateFile, `${JSON.stringify(state, null, 2)}\n`, 'utf8');
await chmod(stateFile, 0o600);
await Promise.all([deleteApp(advisorApp), deleteApp(subjectApp)]);
if (process.argv.includes('--shell')) {
  const shellQuote = (value) => `'${String(value).replaceAll("'", "'\\''")}'`;
  const values = {
    VITE_FIREBASE_API_KEY: firebaseConfig.apiKey,
    VITE_FIREBASE_AUTH_DOMAIN: firebaseConfig.authDomain,
    VITE_FIREBASE_PROJECT_ID: firebaseConfig.projectId,
    VITE_FIREBASE_STORAGE_BUCKET: firebaseConfig.storageBucket,
    VITE_FIREBASE_MESSAGING_SENDER_ID: firebaseConfig.messagingSenderId,
    VITE_FIREBASE_APP_ID: firebaseConfig.appId,
    VITE_USE_FIREBASE_EMULATOR: 'true',
    VITE_FIREBASE_EMULATOR_AUTH_MODE: authMode,
    VITE_FIREBASE_EMULATOR_ADVISOR_EMAIL: advisorEmail,
    VITE_FIREBASE_EMULATOR_ADVISOR_PASSWORD: password,
    MEDINAG_E2E_HOUSEHOLD_ID: householdId,
    MEDINAG_E2E_SUBJECT_EMAIL: subjectEmail,
    MEDINAG_E2E_SUBJECT_PASSWORD: password
  };
  for (const [name, value] of Object.entries(values)) {
    process.stdout.write(`export ${name}=${shellQuote(value)}\n`);
  }
} else {
  process.stdout.write(`${stateFile}\n`);
}
