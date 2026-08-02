import assert from 'node:assert/strict';
import { after, before, beforeEach, test } from 'node:test';
import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment
} from '@firebase/rules-unit-testing';
import {
  Timestamp,
  doc,
  getDoc,
  setDoc,
  updateDoc
} from 'firebase/firestore';
import { readFile } from 'node:fs/promises';

const projectId = 'demo-medinag';
const householdId = 'lori-household';
const now = Timestamp.fromDate(new Date('2026-08-02T12:00:00Z'));
let environment;

const schedule = {
  medicationName: 'Morning meds',
  scheduledTime: '08:00',
  daysOfWeek: [1, 2, 3, 4, 5, 6, 7],
  active: true,
  createdAt: now,
  updatedAt: now
};

const event = {
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
    firestore: {
      rules: await readFile('firestore.rules', 'utf8')
    }
  });
});

beforeEach(async () => {
  await environment.clearFirestore();
  await environment.withSecurityRulesDisabled(async (context) => {
    const database = context.firestore();
    await setDoc(doc(database, 'households', householdId), {
      advisorUid: 'lori',
      name: "Lori's household",
      subjectName: 'Steve',
      migrationVersion: 1,
      createdAt: now,
      updatedAt: now
    });
    await setDoc(doc(database, 'households', householdId, 'members', 'lori'), {
      uid: 'lori',
      role: 'advisor',
      displayName: 'Lori',
      email: 'lori@example.com',
      createdAt: now,
      updatedAt: now
    });
    await setDoc(doc(database, 'households', householdId, 'members', 'steve'), {
      uid: 'steve',
      role: 'subject',
      displayName: 'Steve',
      email: 'steve@example.com',
      createdAt: now,
      updatedAt: now
    });
    await setDoc(doc(database, 'households', householdId, 'schedules', 'morning'), schedule);
    await setDoc(doc(database, 'households', householdId, 'medicationEvents', 'dose'), event);
  });
});

after(async () => {
  await environment.cleanup();
});

test('an anonymous owner can read only their legacy schedules', async () => {
  const lori = environment.authenticatedContext('legacy-lori').firestore();
  await assertSucceeds(
    setDoc(doc(lori, 'admins', 'legacy-lori', 'schedules', 'morning'), schedule)
  );
  await assertSucceeds(
    getDoc(doc(lori, 'admins', 'legacy-lori', 'schedules', 'morning'))
  );
  await assertFails(
    getDoc(doc(lori, 'admins', 'someone-else', 'schedules', 'morning'))
  );
});

test('a signed-in user can establish their own household and advisor membership', async () => {
  const alex = environment.authenticatedContext('alex').firestore();
  const alexHousehold = doc(alex, 'households', 'alex');
  await assertSucceeds(
    setDoc(alexHousehold, {
      advisorUid: 'alex',
      name: "Alex's household",
      subjectName: 'Steve',
      migrationVersion: 0,
      createdAt: now,
      updatedAt: now
    })
  );
  await assertSucceeds(
    setDoc(doc(alex, 'households', 'alex', 'members', 'alex'), {
      uid: 'alex',
      role: 'advisor',
      displayName: 'Alex',
      email: 'alex@example.com',
      createdAt: now,
      updatedAt: now
    })
  );
  await assertSucceeds(
    updateDoc(alexHousehold, {
      migrationVersion: 1,
      updatedAt: now
    })
  );
  await assertFails(
    setDoc(doc(alex, 'households', 'someone-elses-id'), {
      advisorUid: 'alex',
      name: "Alex's second household",
      subjectName: 'Steve',
      migrationVersion: 1,
      createdAt: now,
      updatedAt: now
    })
  );
});

test('the advisor manages schedules while the subject has read-only access', async () => {
  const lori = environment.authenticatedContext('lori').firestore();
  const steve = environment.authenticatedContext('steve').firestore();
  const stranger = environment.authenticatedContext('stranger').firestore();
  const path = ['households', householdId, 'schedules', 'morning'];

  await assertSucceeds(updateDoc(doc(lori, ...path), { scheduledTime: '08:15', updatedAt: now }));
  await assertSucceeds(getDoc(doc(steve, ...path)));
  await assertFails(updateDoc(doc(steve, ...path), { active: false, updatedAt: now }));
  await assertFails(getDoc(doc(stranger, ...path)));
});

test('the subject can snooze or complete a dose without changing its prescription', async () => {
  const steve = environment.authenticatedContext('steve').firestore();
  const eventReference = doc(
    steve,
    'households',
    householdId,
    'medicationEvents',
    'dose'
  );

  await assertSucceeds(
    updateDoc(eventReference, {
      status: 'snoozed',
      snoozeCount: 1,
      lastSnoozedAt: now,
      updatedAt: now
    })
  );
  await assertSucceeds(
    updateDoc(eventReference, {
      status: 'completed',
      completedAt: now,
      updatedAt: now
    })
  );
  await assertFails(
    updateDoc(eventReference, {
      medicationName: 'Something else',
      updatedAt: now
    })
  );

  const result = await assertSucceeds(getDoc(eventReference));
  assert.equal(result.data().status, 'completed');
});
