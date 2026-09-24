import { initializeApp } from 'firebase-admin/app';
import {
  FieldValue,
  Timestamp,
  getFirestore,
  type DocumentData,
  type DocumentReference
} from 'firebase-admin/firestore';
import { logger } from 'firebase-functions';
import { defineSecret } from 'firebase-functions/params';
import { onDocumentWritten } from 'firebase-functions/v2/firestore';
import { onSchedule } from 'firebase-functions/v2/scheduler';
import { buildOccurrences, type DoseDefinition } from './materialization.js';

initializeApp();

const database = getFirestore();
const horizonDays = 7;
const twilioAccountSid = defineSecret('TWILIO_ACCOUNT_SID');
const twilioAuthToken = defineSecret('TWILIO_AUTH_TOKEN');
const twilioFromNumber = defineSecret('TWILIO_FROM_NUMBER');

interface IncidentInput {
  code: string;
  message: string;
  severity: 'warning' | 'critical';
  source: 'backend' | 'ios';
  patientUid?: string;
  deviceId?: string;
  context?: Record<string, string | number | boolean | null>;
}

function incidentReference(
  administratorId: string,
  incidentId: string
): DocumentReference {
  return database.doc(
    `administrators/${administratorId}/systemIncidents/${incidentId}`
  );
}

async function recordIncident(
  administratorId: string,
  incidentId: string,
  input: IncidentInput
): Promise<void> {
  const reference = incidentReference(administratorId, incidentId);
  const existing = await reference.get();
  const existingData = existing.data();
  const lastAlert = existingData?.smsLastAttemptAt instanceof Timestamp
    ? existingData.smsLastAttemptAt.toMillis()
    : 0;
  const severityIncreased = existingData?.severity === 'warning'
    && input.severity === 'critical';
  const cooldownElapsed = lastAlert > 0
    && Date.now() - lastAlert >= 24 * 60 * 60 * 1000;
  const shouldAlert = !existing.exists
    || existingData?.status === 'resolved'
    || severityIncreased
    || cooldownElapsed;
  const sequence = Number(existingData?.alertSequence ?? 0)
    + (shouldAlert ? 1 : 0);
  await reference.set({
    ...input,
    administratorUid: administratorId,
    status: 'open',
    firstOccurredAt: existingData?.firstOccurredAt ?? FieldValue.serverTimestamp(),
    lastOccurredAt: FieldValue.serverTimestamp(),
    occurrenceCount: FieldValue.increment(1),
    alertSequence: sequence,
    smsState: shouldAlert ? 'queued' : existingData?.smsState ?? 'queued',
    smsAttempts: Number(existingData?.smsAttempts ?? 0),
    updatedAt: FieldValue.serverTimestamp()
  }, { merge: true });
}

function doseFromDocument(id: string, data: DocumentData): DoseDefinition | null {
  if (
    typeof data.medicationName !== 'string'
    || typeof data.scheduledTime !== 'string'
    || !Array.isArray(data.daysOfWeek)
    || typeof data.active !== 'boolean'
  ) return null;
  return {
    id,
    medicationName: data.medicationName,
    scheduledTime: data.scheduledTime,
    daysOfWeek: data.daysOfWeek.map(Number),
    active: data.active
  };
}

async function reconcileAdministrator(
  administratorId: string,
  now = new Date()
): Promise<void> {
  const administratorReference = database.doc(`administrators/${administratorId}`);
  const administratorSnapshot = await administratorReference.get();
  if (!administratorSnapshot.exists) return;
  const administrator = administratorSnapshot.data() ?? {};
  const patientUid = typeof administrator.patientUid === 'string'
    ? administrator.patientUid
    : null;
  const published = administrator.published === true;
  let patientTimeZone: string | null = null;
  if (patientUid) {
    const patient = await database.doc(`patients/${patientUid}`).get();
    const value = patient.data()?.timeZone;
    patientTimeZone = typeof value === 'string' && value.length > 0 ? value : null;
  }

  const dosesSnapshot = await administratorReference.collection('doses').get();
  const eventsReference = administratorReference.collection('medicationEvents');
  const eventsSnapshot = await eventsReference.get();
  const desired = new Map<string, ReturnType<typeof buildOccurrences>[number]>();

  if (published && patientUid && patientTimeZone) {
    for (const document of dosesSnapshot.docs) {
      const dose = doseFromDocument(document.id, document.data());
      if (!dose) {
        await recordIncident(administratorId, `invalid-dose-${document.id}`, {
          code: 'invalid_dose',
          message: `Dose ${document.id} could not be materialized.`,
          severity: 'critical',
          source: 'backend',
          patientUid,
          context: { doseId: document.id }
        });
        continue;
      }
      for (const occurrence of buildOccurrences(
        dose,
        patientTimeZone,
        now,
        horizonDays
      )) desired.set(occurrence.id, occurrence);
    }
  }

  const batch = database.batch();
  for (const document of eventsSnapshot.docs) {
    const data = document.data();
    const scheduled = data.scheduledTime instanceof Timestamp
      ? data.scheduledTime.toDate()
      : null;
    const actionable = data.status !== 'completed';
    if (actionable && scheduled && scheduled > now && !desired.has(document.id)) {
      batch.delete(document.ref);
    }
  }

  for (const occurrence of desired.values()) {
    const reference = eventsReference.doc(occurrence.id);
    const existing = eventsSnapshot.docs.find(({ id }) => id === occurrence.id);
    if (existing?.data().status === 'completed') continue;
    batch.set(reference, {
      scheduleId: occurrence.scheduleId,
      medicationName: occurrence.medicationName,
      occurrenceDate: occurrence.occurrenceDate,
      scheduledLocalTime: occurrence.scheduledLocalTime,
      timeZone: occurrence.timeZone,
      scheduledTime: Timestamp.fromDate(occurrence.scheduledTime),
      status: existing?.data().status === 'snoozed' ? 'snoozed' : 'pending',
      snoozeCount: Number(existing?.data().snoozeCount ?? 0),
      lastSnoozedAt: existing?.data().lastSnoozedAt ?? null,
      completedAt: null,
      createdAt: existing?.data().createdAt ?? FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp()
    });
  }
  await batch.commit();
}

async function reconcileWithIncident(administratorId: string): Promise<void> {
  try {
    await reconcileAdministrator(administratorId);
  } catch (error) {
    logger.error('Medication occurrence reconciliation failed.', {
      administratorId,
      error
    });
    await recordIncident(administratorId, 'materialization-failure', {
      code: 'materialization_failed',
      message: 'Upcoming medication reminders could not be prepared.',
      severity: 'critical',
      source: 'backend'
    });
    throw error;
  }
}

export const reconcileDoseWrite = onDocumentWritten(
  'administrators/{administratorId}/doses/{doseId}',
  async (event) => reconcileWithIncident(event.params.administratorId)
);

export const reconcileAdministratorWrite = onDocumentWritten(
  'administrators/{administratorId}',
  async (event) => reconcileWithIncident(event.params.administratorId)
);

export const reconcilePatientWrite = onDocumentWritten(
  'patients/{patientId}',
  async (event) => {
    const before = event.data?.before.data();
    const after = event.data?.after.data();
    const administratorIds = new Set([
      before?.followingAdministratorUid,
      after?.followingAdministratorUid
    ].filter((value): value is string => typeof value === 'string'));
    await Promise.all([...administratorIds].map(reconcileWithIncident));
  }
);

export const extendOccurrenceHorizons = onSchedule(
  { schedule: 'every day 00:15', timeZone: 'UTC' },
  async () => {
    const administrators = await database.collection('administrators')
      .where('published', '==', true)
      .get();
    await Promise.all(
      administrators.docs.map(({ id }) => reconcileWithIncident(id))
    );
  }
);

export const monitorDeviceCoverage = onSchedule(
  { schedule: 'every 6 hours', timeZone: 'UTC' },
  async () => {
    const threshold = Timestamp.fromMillis(Date.now() + 48 * 60 * 60 * 1000);
    const coverage = await database.collectionGroup('deviceCoverage')
      .where('scheduledThrough', '<', threshold)
      .get();
    await Promise.all(coverage.docs.map(async (document) => {
      const administrator = document.ref.parent.parent;
      if (!administrator) return;
      const data = document.data();
      await recordIncident(administrator.id, `coverage-${document.id}`, {
        code: 'schedule_coverage_low',
        message: 'The patient phone has less than 48 hours of confirmed reminders.',
        severity: 'critical',
        source: 'backend',
        patientUid: typeof data.patientUid === 'string' ? data.patientUid : undefined,
        deviceId: document.id,
        context: {
          scheduledThrough: data.scheduledThrough instanceof Timestamp
            ? data.scheduledThrough.toDate().toISOString()
            : null
        }
      });
    }));
  }
);

export const reconcileCoverageIncident = onDocumentWritten(
  'administrators/{administratorId}/deviceCoverage/{patientId}',
  async (event) => {
    const coverage = event.data?.after.data();
    if (!coverage) return;
    const administratorId = event.params.administratorId;
    const patientId = event.params.patientId;
    const ready = coverage.reconciliationStatus === 'ready'
      && coverage.expectedPendingCount > 0
      && coverage.expectedPendingCount === coverage.actualPendingCount;
    if (!ready) {
      await recordIncident(administratorId, `coverage-${patientId}`, {
        code: 'notification_reconciliation_failed',
        message: 'The patient phone does not have all expected reminders registered.',
        severity: 'critical',
        source: 'backend',
        patientUid: patientId,
        deviceId: typeof coverage.deviceId === 'string'
          ? coverage.deviceId
          : undefined,
        context: {
          expectedPendingCount: Number(coverage.expectedPendingCount ?? 0),
          actualPendingCount: Number(coverage.actualPendingCount ?? 0)
        }
      });
      return;
    }
    const incidents = await database.collection(
      `administrators/${administratorId}/systemIncidents`
    ).where('patientUid', '==', patientId).get();
    const batch = database.batch();
    for (const incident of incidents.docs) {
      if (incident.data().status !== 'open') continue;
      if (![
        'notification_reconciliation_failed',
        'notification_authorization_denied',
        'schedule_coverage_low',
        'device_coverage_write_failed',
        'background_refresh_failed',
        'background_refresh_expired'
      ].includes(String(incident.data().code))) continue;
      batch.update(incident.ref, {
        status: 'resolved',
        resolvedAt: FieldValue.serverTimestamp(),
        resolution: 'Device coverage recovered and pending reminders match.',
        updatedAt: FieldValue.serverTimestamp()
      });
    }
    await batch.commit();
  }
);

async function sendTwilioSms(to: string, body: string): Promise<{
  messageId: string;
  providerState: string;
}> {
  const accountSid = process.env.TWILIO_ACCOUNT_SID ?? twilioAccountSid.value();
  const authToken = process.env.TWILIO_AUTH_TOKEN ?? twilioAuthToken.value();
  const from = process.env.TWILIO_FROM_NUMBER ?? twilioFromNumber.value();
  const baseUrl = process.env.MEDINAG_TWILIO_BASE_URL ?? 'https://api.twilio.com';
  const response = await fetch(
    `${baseUrl}/2010-04-01/Accounts/${encodeURIComponent(accountSid)}/Messages.json`,
    {
      method: 'POST',
      headers: {
        authorization: `Basic ${Buffer.from(`${accountSid}:${authToken}`).toString('base64')}`,
        'content-type': 'application/x-www-form-urlencoded'
      },
      body: new URLSearchParams({ To: to, From: from, Body: body })
    }
  );
  const result = await response.json() as { sid?: string; status?: string; message?: string };
  if (!response.ok || !result.sid) {
    throw new Error(result.message ?? `Twilio rejected the message with ${response.status}.`);
  }
  return { messageId: result.sid, providerState: result.status ?? 'accepted' };
}

export const alertAdministrator = onDocumentWritten(
  {
    document: 'administrators/{administratorId}/systemIncidents/{incidentId}',
    secrets: [twilioAccountSid, twilioAuthToken, twilioFromNumber]
  },
  async (event) => {
    const incident = event.data?.after.data();
    if (!incident || incident.status !== 'open' || incident.smsState !== 'queued') return;
    const reference = event.data?.after.ref;
    if (!reference) return;
    const claimed = await database.runTransaction(async (transaction) => {
      const snapshot = await transaction.get(reference);
      if (snapshot.data()?.smsState !== 'queued') return false;
      transaction.update(reference, {
        smsState: 'sending',
        smsAttempts: FieldValue.increment(1),
        smsLastAttemptAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp()
      });
      return true;
    });
    if (!claimed) return;

    const administrator = await database.doc(
      `administrators/${event.params.administratorId}`
    ).get();
    const smsNumber = administrator.data()?.smsNumber;
    if (typeof smsNumber !== 'string' || smsNumber.length === 0) {
      await reference.update({
        smsState: 'missing_destination',
        smsError: 'The administrator has no configured SMS number.',
        updatedAt: FieldValue.serverTimestamp()
      });
      return;
    }

    try {
      const result = await sendTwilioSms(
        smsNumber,
        `MediNag alert: ${String(incident.message)}`
      );
      await reference.update({
        smsState: 'accepted',
        smsProviderState: result.providerState,
        smsProviderMessageId: result.messageId,
        smsAcceptedAt: FieldValue.serverTimestamp(),
        smsError: FieldValue.delete(),
        updatedAt: FieldValue.serverTimestamp()
      });
    } catch (error) {
      logger.error('Administrator SMS delivery failed.', { error });
      await reference.update({
        smsState: 'failed',
        smsError: error instanceof Error ? error.message : 'Unknown SMS error',
        updatedAt: FieldValue.serverTimestamp()
      });
    }
  }
);
