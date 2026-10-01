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
const legacyHouseholdId = 'legacy-household';
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
  occurrenceDate: '2026-09-09',
  scheduledLocalTime: '08:00',
  timeZone: 'America/Toronto',
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
      timeZone: 'America/Toronto',
      timeZoneUpdatedAt: now,
      createdAt: now,
      updatedAt: now
    });
    await setDoc(doc(database, 'households', legacyHouseholdId), {
      advisorUid: 'legacy-lori',
      name: "Lori's household",
      subjectName: 'Legacy Steve',
      migrationVersion: 1,
      createdAt: now,
      updatedAt: now
    });
    await setDoc(
      doc(database, 'households', legacyHouseholdId, 'members', 'legacy-lori'),
      {
        uid: 'legacy-lori',
        role: 'advisor',
        displayName: 'Legacy Lori',
        email: 'legacy-lori@example.com',
        createdAt: now,
        updatedAt: now
      }
    );
    await setDoc(
      doc(database, 'households', legacyHouseholdId, 'members', 'legacy-steve'),
      {
        uid: 'legacy-steve',
        role: 'subject',
        displayName: 'Legacy Steve',
        email: 'legacy-steve@example.com',
        createdAt: now,
        updatedAt: now
      }
    );
    await setDoc(
      doc(database, 'households', legacyHouseholdId, 'schedules', 'morning'),
      dose
    );
    await setDoc(
      doc(database, 'households', legacyHouseholdId, 'medicationEvents', 'dose'),
      medicationEvent
    );
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
    timeZone: 'America/Vancouver',
    timeZoneUpdatedAt: now,
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

test('the linked patient reports real device coverage for administrator review', async () => {
  const steve = environment.authenticatedContext('steve').firestore();
  const coverage = {
    patientUid: 'steve',
    deviceId: 'iphone-steve',
    timeZone: 'America/Toronto',
    lastRefreshAt: now,
    scheduledThrough: now,
    applicationBuild: '0.1.0 (2)',
    reconciliationStatus: 'ready',
    expectedPendingCount: 7,
    actualPendingCount: 7,
    updatedAt: now
  };
  await assertSucceeds(setDoc(doc(
    steve,
    'administrators',
    'lori',
    'deviceCoverage',
    'steve'
  ), coverage));
  const lori = environment.authenticatedContext('lori').firestore();
  await assertSucceeds(getDoc(doc(
    lori,
    'administrators',
    'lori',
    'deviceCoverage',
    'steve'
  )));
  const stranger = environment.authenticatedContext('stranger').firestore();
  await assertFails(setDoc(doc(
    stranger,
    'administrators',
    'lori',
    'deviceCoverage',
    'stranger'
  ), { ...coverage, patientUid: 'stranger' }));
});

test('client incidents are visible to the administrator but cannot forge SMS results', async () => {
  const steve = environment.authenticatedContext('steve').firestore();
  const incidentReference = doc(
    steve,
    'administrators',
    'lori',
    'systemIncidents',
    'iphone-steve-notification-permission'
  );
  const incident = {
    administratorUid: 'lori',
    patientUid: 'steve',
    deviceId: 'iphone-steve',
    code: 'notification_permission_denied',
    message: 'Medication notifications are disabled.',
    severity: 'critical',
    source: 'ios',
    status: 'open',
    firstOccurredAt: now,
    lastOccurredAt: now,
    occurrenceCount: 1,
    alertSequence: 1,
    smsState: 'queued',
    smsAttempts: 0,
    context: { authorizationStatus: 'denied' },
    updatedAt: now
  };
  await assertSucceeds(setDoc(incidentReference, incident));
  await assertSucceeds(updateDoc(incidentReference, {
    lastOccurredAt: now,
    occurrenceCount: 2,
    context: { authorizationStatus: 'still-denied' },
    updatedAt: now
  }));
  await assertFails(updateDoc(incidentReference, {
    lastOccurredAt: now,
    occurrenceCount: 3,
    smsState: 'delivered',
    updatedAt: now
  }));
  const lori = environment.authenticatedContext('lori').firestore();
  await assertSucceeds(getDoc(doc(
    lori,
    'administrators',
    'lori',
    'systemIncidents',
    'iphone-steve-notification-permission'
  )));
  await assertFails(setDoc(
    doc(steve, 'administrators', 'lori', 'systemIncidents', 'forged'),
    { ...incident, smsState: 'delivered', smsAttempts: 1 }
  ));
  await assertFails(updateDoc(incidentReference, { status: 'resolved' }));
});

test('the production dashboard can keep writing the legacy owner schedule during migration', async () => {
  const lori = environment.authenticatedContext('legacy-lori').firestore();
  await assertSucceeds(setDoc(
    doc(lori, 'admins', 'legacy-lori', 'schedules', 'morning'),
    dose
  ));
  await assertSucceeds(updateDoc(
    doc(lori, 'admins', 'legacy-lori', 'schedules', 'morning'),
    { scheduledTime: '08:15', updatedAt: now }
  ));
  const stranger = environment.authenticatedContext('stranger').firestore();
  await assertFails(setDoc(
    doc(stranger, 'admins', 'legacy-lori', 'schedules', 'evening'),
    dose
  ));
});

test('a new administrator can inspect an empty same-ID legacy household', async () => {
  const alex = environment.authenticatedContext('new-alex').firestore();
  const emptySchedules = await assertSucceeds(getDocs(collection(
    alex,
    'households',
    'new-alex',
    'schedules'
  )));
  assert.equal(emptySchedules.empty, true);
  const stranger = environment.authenticatedContext('stranger').firestore();
  await assertFails(getDocs(collection(
    stranger,
    'households',
    'new-alex',
    'schedules'
  )));
});

test('the production dashboard retains legacy household administration', async () => {
  const alex = environment.authenticatedContext('legacy-alex').firestore();
  const household = doc(alex, 'households', 'legacy-alex');
  await assertSucceeds(setDoc(household, {
    advisorUid: 'legacy-alex',
    name: "Alex's household",
    subjectName: 'Patient',
    migrationVersion: 0,
    createdAt: now,
    updatedAt: now
  }));
  await assertSucceeds(setDoc(
    doc(alex, 'households', 'legacy-alex', 'members', 'legacy-alex'),
    {
      uid: 'legacy-alex',
      role: 'advisor',
      displayName: 'Legacy Alex',
      email: 'legacy-alex@example.com',
      createdAt: now,
      updatedAt: now
    }
  ));
  await assertSucceeds(setDoc(
    doc(alex, 'households', 'legacy-alex', 'schedules', 'morning'),
    dose
  ));
  await assertSucceeds(updateDoc(household, {
    migrationVersion: 1,
    updatedAt: now
  }));
});

test('legacy subjects can respond but cannot rewrite prescriptions', async () => {
  const steve = environment.authenticatedContext('legacy-steve').firestore();
  const eventReference = doc(
    steve,
    'households',
    legacyHouseholdId,
    'medicationEvents',
    'dose'
  );
  await assertSucceeds(updateDoc(eventReference, {
    status: 'snoozed',
    snoozeCount: 1,
    lastSnoozedAt: now,
    updatedAt: now
  }));
  await assertFails(updateDoc(eventReference, {
    medicationName: 'Something else',
    updatedAt: now
  }));
  await assertSucceeds(getDoc(doc(
    steve,
    'households',
    legacyHouseholdId,
    'schedules',
    'morning'
  )));
});
