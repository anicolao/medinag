import { expect, test } from '@playwright/test';
import { readFileSync } from 'node:fs';
import { initializeApp } from 'firebase/app';
import { connectAuthEmulator, getAuth, GoogleAuthProvider, signInWithCredential } from 'firebase/auth';
import { collection, connectFirestoreEmulator, getDocs, getFirestore } from 'firebase/firestore';

test('the early completion and actual alarm evidence return to the administrator', async ({ page }, info) => {
  const reliability = process.env.MEDINAG_PATIENT_SCHEME === 'MediNagAlarmReliability';
  const file = process.env.MEDINAG_E2E_STATE_FILE;
  if (!file) throw new Error('Connected environment required.');
  await page.goto('/#/today', { waitUntil: 'domcontentloaded' });
  await expect(page.getByTestId('today-event-list')).toContainText('Completed');
  const state = JSON.parse(readFileSync(file, 'utf8'));
  const app = initializeApp(state.firebase, 'alarmkit-evidence-reader');
  const auth = getAuth(app);
  connectAuthEmulator(auth, `http://${state.emulators.authHost}`, { disableWarnings: true });
  await signInWithCredential(auth, GoogleAuthProvider.credential(state.administrator.googleIdToken));
  const db = getFirestore(app);
  const [host, port] = state.emulators.firestoreHost.split(':');
  connectFirestoreEmulator(db, host, Number(port));
  const evidence = (await getDocs(collection(db, 'administrators', state.administratorId, 'deviceEvents')))
    .docs.map(doc => doc.data());
  expect(evidence.some(event => event.kind === 'registration_verified')).toBeTruthy();
  expect(evidence.some(event => event.kind === 'patient_response_saved')).toBeTruthy();
  expect(evidence.some(event => event.kind === 'dose_cancellation_verified')).toBeTruthy();
  expect(evidence.every(event => event.receivedAt && event.observedAt)).toBeTruthy();
  const coverage = (await getDocs(collection(db, 'administrators', state.administratorId, 'deviceCoverage')))
    .docs.map(doc => doc.data());
  expect(coverage).toHaveLength(1);
  expect(coverage[0].actualPendingCount).toBe(reliability ? 18 : 62);
  expect(coverage[0].reconciliationStatus).toBe('ready');
  expect((await getDocs(collection(db, 'administrators', state.administratorId, 'systemIncidents'))).size).toBe(0);
  const eventDocs = (await getDocs(collection(db, 'administrators', state.administratorId, 'medicationEvents'))).docs;
  const events = eventDocs.map(doc => doc.data());
  const completed = events.filter(event => event.status === 'completed');
  expect(completed).toHaveLength(1);
  expect(completed[0].completedAt.toMillis()).toBeLessThan(completed[0].scheduledTime.toMillis());
  expect(completed[0].scheduledTime.toMillis() - completed[0].completedAt.toMillis()).toBeLessThanOrEqual(900_000);
  // SDK-backed evidence is checked below using the actual event document ID.
  const completedDocs = eventDocs.filter(doc => doc.data().status === 'completed');
  const deadlines = evidence.filter(event => event.kind === 'registration_requested'
    && event.eventId === completedDocs[0].id).map(event => Date.parse(event.detail.split('deadline=')[1]));
  const origin = completed[0].scheduledTime.toMillis();
  expect([...new Set(deadlines)].sort((a, b) => a - b))
    .toEqual(reliability ? [origin] : Array.from({ length: 31 }, (_, index) => origin + index * 60_000));
  if (reliability) {
    const actualTimes = new Map(eventDocs.map(doc => [doc.id, doc.data().scheduledTime.toMillis()]));
    for (const registration of evidence.filter(event => event.kind === 'registration_requested')) {
      expect(Date.parse(registration.detail.split('deadline=')[1])).toBe(actualTimes.get(registration.eventId));
    }
    expect(evidence.some(event => event.kind === 'inventory_verified'
      && event.detail.includes('one per original dose time'))).toBeTruthy();
  }
  await info.attach('actual-returned-completion', { body: await page.screenshot(), contentType: 'image/png' });
});
