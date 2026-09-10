import { randomBytes, randomInt, randomUUID } from 'node:crypto';
import { chmod, writeFile } from 'node:fs/promises';
import { deleteApp, initializeApp } from 'firebase/app';
import {
  connectAuthEmulator,
  getAuth,
  GoogleAuthProvider,
  signInWithCredential
} from 'firebase/auth';
import {
  connectFirestoreEmulator,
  getFirestore,
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
const administratorName = required('MEDINAG_E2E_ADMINISTRATOR_NAME');
const patientName = required('MEDINAG_E2E_PATIENT_NAME');
const stateFile = required('MEDINAG_E2E_STATE_FILE');
const authMode = process.env.MEDINAG_E2E_AUTH_MODE ?? 'administrator';
if (!['administrator', 'signed-out'].includes(authMode)) {
  throw new Error('MEDINAG_E2E_AUTH_MODE must be administrator or signed-out.');
}
const runId = randomUUID();
const messagingSenderId = String(randomInt(100_000_000_000, 999_999_999_999));
const firebaseConfig = {
  apiKey: `AIzaSy${randomBytes(25).toString('base64url')}`,
  authDomain: `${projectId}.firebaseapp.com`,
  projectId,
  storageBucket: `${projectId}.appspot.com`,
  messagingSenderId,
  appId: `1:${messagingSenderId}:ios:${randomBytes(16).toString('hex')}`
};

const administratorApp = initializeApp(firebaseConfig, `administrator-${runId}`);
const administratorAuth = getAuth(administratorApp);
connectAuthEmulator(administratorAuth, `http://${authHost}`, { disableWarnings: true });
const administratorDatabase = getFirestore(administratorApp);
const [firestoreHostname, firestorePort] = firestoreHost.split(':');
connectFirestoreEmulator(
  administratorDatabase,
  firestoreHostname,
  Number(firestorePort)
);

// The emulator is discarded after every story, so these provider identities are
// freshly created while retaining deterministic user-visible text and UIDs for
// exact screenshot comparison. The credential token itself is generated here.
const administratorEmail = 'administrator-e2e@medinag.invalid';
const administratorGoogleIdToken = JSON.stringify({
  sub: 'medinag-administrator-e2e',
  email: administratorEmail,
  email_verified: true,
  name: administratorName
});
const administrator = await signInWithCredential(
  administratorAuth,
  GoogleAuthProvider.credential(administratorGoogleIdToken)
);

const patientApp = initializeApp(firebaseConfig, `patient-${runId}`);
const patientAuth = getAuth(patientApp);
connectAuthEmulator(patientAuth, `http://${authHost}`, { disableWarnings: true });
const patientEmail = 'patient-e2e@medinag.invalid';
const patientGoogleIdToken = JSON.stringify({
  sub: 'medinag-patient-e2e',
  email: patientEmail,
  email_verified: true,
  name: patientName
});
const patient = await signInWithCredential(
  patientAuth,
  GoogleAuthProvider.credential(patientGoogleIdToken)
);

const state = {
  runId,
  firebase: firebaseConfig,
  emulators: { authHost, firestoreHost },
  administratorId: administrator.user.uid,
  administrator: {
    uid: administrator.user.uid,
    email: administratorEmail,
    googleIdToken: administratorGoogleIdToken
  },
  patient: {
    uid: patient.user.uid,
    email: patientEmail,
    googleIdToken: patientGoogleIdToken
  }
};
await writeFile(stateFile, `${JSON.stringify(state, null, 2)}\n`, 'utf8');
await chmod(stateFile, 0o600);
await Promise.all([deleteApp(administratorApp), deleteApp(patientApp)]);
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
    VITE_FIREBASE_EMULATOR_GOOGLE_ID_TOKEN_BASE64: authMode === 'administrator'
      ? Buffer.from(administratorGoogleIdToken, 'utf8').toString('base64')
      : '',
    MEDINAG_E2E_ADMINISTRATOR_ID: administrator.user.uid,
    MEDINAG_E2E_ADMINISTRATOR_NAME: administratorName,
    MEDINAG_E2E_PATIENT_EMAIL: patientEmail,
    MEDINAG_E2E_GOOGLE_ID_TOKEN_BASE64: Buffer.from(
      patientGoogleIdToken,
      'utf8'
    ).toString('base64')
  };
  for (const [name, value] of Object.entries(values)) {
    process.stdout.write(`export ${name}=${shellQuote(value)}\n`);
  }
} else {
  process.stdout.write(`${stateFile}\n`);
}
