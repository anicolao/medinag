import assert from 'node:assert/strict';
import { after, before, beforeEach, test } from 'node:test';
import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment
} from '@firebase/rules-unit-testing';
import {
  Timestamp,
  collection,
  doc,
  getDoc,
  getDocs,
  query,
  setDoc,
  updateDoc,
  where
} from 'firebase/firestore';
import { readFile } from 'node:fs/promises';

const projectId = 'demo-medinag';
const now = Timestamp.fromDate(new Date('2026-09-09T12:00:00Z'));
let environment;

const administrator = {
  uid: 'lori',
  displayName: 'Lori',
  email: 'lori@example.com',
  planName: "Lori's medication schedule",
  planCode: 'LORI-4821',
  published: true,
  patientUid: 'steve',
  patientDisplayName: 'Steve',
  snoozeIntervalMinutes: 10,
  escalationDeadlineMinutes: 30,
  maxReminders: 3,
  timeZone: 'America/Toronto',
  smsNumber: '+12267475188',
  createdAt: now,
  updatedAt: now
};

const dose = {
  medicationName: 'Morning meds',
  scheduledTime: '08:00',
  daysOfWeek: [1, 2, 3, 4, 5, 6, 7],
  active: true,
  createdAt: now,
  updatedAt: now
};

const medicationEvent = {
  scheduleId: 'morning',
  medicationName: 'Morning meds',
  scheduledTime: now,
  status: 'pending',
  snoozeCount: 0,
  lastSnoozedAt: null,
  completedAt: null,
  createdAt: now,
  updatedAt: now
};

before(async () => {
  environment = await initializeTestEnvironment({
    projectId,
    firestore: { rules: await readFile('firestore.rules', 'utf8') }
  });
});

beforeEach(async () => {
  await environment.clearFirestore();
  await environment.withSecurityRulesDisabled(async (context) => {
    const database = context.firestore();
    await setDoc(doc(database, 'administrators', 'lori'), administrator);
    await setDoc(doc(database, 'administrators', 'lori', 'doses', 'morning'), dose);
    await setDoc(
      doc(database, 'administrators', 'lori', 'medicationEvents', 'dose'),
      medicationEvent
    );
    await setDoc(doc(database, 'patients', 'steve'), {
      uid: 'steve',
      displayName: 'Steve',
      email: 'steve@example.com',
      followingAdministratorUid: 'lori',
      createdAt: now,
      updatedAt: now
    });
  });
});

after(async () => environment.cleanup());

test('any signed-in person can create only their own administrator profile', async () => {
  const alex = environment.authenticatedContext('alex').firestore();
  await assertSucceeds(setDoc(doc(alex, 'administrators', 'alex'), {
    ...administrator,
    uid: 'alex',
    email: 'alex@example.com',
    planCode: 'ALEX-1937',
    published: false,
    patientUid: null,
    patientDisplayName: ''
  }));
  await assertFails(setDoc(doc(alex, 'administrators', 'someone-else'), {
    ...administrator,
    uid: 'someone-else',
    planCode: 'ELSE-1937'
  }));
});

test('signed-in patients can discover published plans but not drafts', async () => {
  await environment.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), 'administrators', 'alex'), {
      ...administrator,
      uid: 'alex',
      planCode: 'ALEX-1937',
      published: false,
      patientUid: null,
      patientDisplayName: ''
    });
  });
  const patient = environment.authenticatedContext('visitor').firestore();
  await assertFails(getDoc(doc(
    environment.unauthenticatedContext().firestore(),
    'administrators',
    'lori'
  )));
  const published = await assertSucceeds(getDocs(query(
    collection(patient, 'administrators'),
    where('published', '==', true)
  )));
  assert.equal(published.docs.length, 1);
  await assertFails(getDoc(doc(patient, 'administrators', 'alex')));
  await assertSucceeds(getDoc(doc(patient, 'administrators', 'lori', 'doses', 'morning')));
  await assertFails(updateDoc(
    doc(patient, 'administrators', 'lori', 'doses', 'morning'),
    { active: false, updatedAt: now }
  ));
});

test('an available plan can be claimed by one patient only', async () => {
  await environment.withSecurityRulesDisabled(async (context) => {
    await updateDoc(doc(context.firestore(), 'administrators', 'lori'), {
      patientUid: null,
      patientDisplayName: ''
    });
  });
  const alex = environment.authenticatedContext('alex').firestore();
  await assertSucceeds(updateDoc(doc(alex, 'administrators', 'lori'), {
    patientUid: 'alex',
    patientDisplayName: 'Alex',
    updatedAt: now
  }));
  const robin = environment.authenticatedContext('robin').firestore();
  await assertFails(updateDoc(doc(robin, 'administrators', 'lori'), {
    patientUid: 'robin',
    patientDisplayName: 'Robin',
    updatedAt: now
  }));
});

test('the administrator can disconnect but cannot appoint a patient', async () => {
  const lori = environment.authenticatedContext('lori').firestore();
  await assertSucceeds(updateDoc(doc(lori, 'administrators', 'lori'), {
    patientUid: null,
    patientDisplayName: '',
    updatedAt: now
  }));
  await assertFails(updateDoc(doc(lori, 'administrators', 'lori'), {
    patientUid: 'alex',
    patientDisplayName: 'Alex',
    updatedAt: now
  }));
});

test('a patient owns one following record and cannot rewrite another patient', async () => {
  const alex = environment.authenticatedContext('alex').firestore();
  await assertSucceeds(setDoc(doc(alex, 'patients', 'alex'), {
    uid: 'alex',
    displayName: 'Alex',
    email: 'alex@example.com',
    followingAdministratorUid: null,
    createdAt: now,
    updatedAt: now
  }));
  await assertFails(updateDoc(doc(alex, 'patients', 'steve'), {
    followingAdministratorUid: 'alex',
    updatedAt: now
  }));
});

test('only the linked patient can snooze or complete without changing the dose', async () => {
  const steve = environment.authenticatedContext('steve').firestore();
  const eventReference = doc(
    steve,
    'administrators',
    'lori',
    'medicationEvents',
    'dose'
  );
  await assertSucceeds(updateDoc(eventReference, {
    status: 'snoozed',
    snoozeCount: 1,
    lastSnoozedAt: now,
    updatedAt: now
  }));
  await assertSucceeds(updateDoc(eventReference, {
    status: 'completed',
    completedAt: now,
    updatedAt: now
  }));
  await assertFails(updateDoc(eventReference, {
    medicationName: 'Something else',
    updatedAt: now
  }));
  const stranger = environment.authenticatedContext('stranger').firestore();
  await assertFails(getDoc(doc(
    stranger,
    'administrators',
    'lori',
    'medicationEvents',
    'dose'
  )));
});
