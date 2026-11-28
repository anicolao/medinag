import fs from 'node:fs';
import { initializeApp } from 'firebase/app';
import { connectAuthEmulator, getAuth, GoogleAuthProvider, signInWithCredential } from 'firebase/auth';
import { collection, connectFirestoreEmulator, getDocs, getFirestore } from 'firebase/firestore';

// Diagnostic reads of the actual user-created emulator records, with the
// administrator's real emulator Auth credential and security rules still active.
const state = JSON.parse(fs.readFileSync(process.env.MEDINAG_E2E_STATE_FILE, 'utf8'));
const app = initializeApp(state.firebase, 'alarmkit-diagnostic-reader');
const auth = getAuth(app);
connectAuthEmulator(auth, `http://${state.emulators.authHost}`, { disableWarnings: true });
await signInWithCredential(auth, GoogleAuthProvider.credential(state.administrator.googleIdToken));
const db = getFirestore(app);
const [host, port] = state.emulators.firestoreHost.split(':');
connectFirestoreEmulator(db, host, Number(port));
for (const name of ['deviceEvents', 'systemIncidents', 'deviceCoverage']) {
  const result = await getDocs(collection(db, 'administrators', state.administratorId, name));
  const values = result.docs.map(doc => ({ id: doc.id, ...doc.data() }));
  console.log('ACTUAL_ALARMKIT_DIAGNOSTICS', name, JSON.stringify(name === 'deviceEvents'
    ? values.filter(value => value.kind === 'client_failure' || value.kind === 'patient_response_saved') : values));
}
process.exit(0);
