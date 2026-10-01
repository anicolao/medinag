import assert from 'node:assert/strict';
import test from 'node:test';
import { buildOccurrences, type DoseDefinition } from './materialization.js';

const dailyDose: DoseDefinition = {
  id: 'morning',
  medicationName: 'Morning medication',
  scheduledTime: '08:00',
  daysOfWeek: [1, 2, 3, 4, 5, 6, 7],
  active: true
};

test('materializes seven patient-local calendar days with stable identifiers', () => {
  const occurrences = buildOccurrences(
    dailyDose,
    'America/Toronto',
    new Date('2026-09-23T10:00:00Z')
  );
  assert.equal(occurrences.length, 7);
  assert.equal(occurrences[0]?.id, 'morning_20260923');
  assert.equal(occurrences[0]?.scheduledTime.toISOString(), '2026-09-23T12:00:00.000Z');
  assert.equal(occurrences[6]?.id, 'morning_20260929');
});

test('the same wall-clock time follows the patient rather than the administrator', () => {
  const now = new Date('2026-09-23T00:00:00Z');
  const toronto = buildOccurrences(dailyDose, 'America/Toronto', now)[0];
  const vancouver = buildOccurrences(dailyDose, 'America/Vancouver', now)[0];
  assert.equal(toronto?.scheduledLocalTime, '08:00');
  assert.equal(vancouver?.scheduledLocalTime, '08:00');
  assert.equal(toronto?.scheduledTime.toISOString(), '2026-09-23T12:00:00.000Z');
  assert.equal(vancouver?.scheduledTime.toISOString(), '2026-09-23T15:00:00.000Z');
});

test('daylight-saving changes preserve patient-local medication time', () => {
  const occurrences = buildOccurrences(
    dailyDose,
    'America/Toronto',
    new Date('2026-10-30T12:00:00Z')
  );
  const before = occurrences.find(({ occurrenceDate }) => occurrenceDate === '2026-10-31');
  const after = occurrences.find(({ occurrenceDate }) => occurrenceDate === '2026-11-01');
  assert.equal(before?.scheduledTime.toISOString(), '2026-10-31T12:00:00.000Z');
  assert.equal(after?.scheduledTime.toISOString(), '2026-11-01T13:00:00.000Z');
});

test('inactive doses and elapsed times do not create actionable occurrences', () => {
  assert.deepEqual(buildOccurrences({ ...dailyDose, active: false }, 'UTC', new Date()), []);
  const occurrences = buildOccurrences(
    dailyDose,
    'America/Toronto',
    new Date('2026-09-23T13:00:00Z')
  );
  assert.equal(occurrences[0]?.occurrenceDate, '2026-09-24');
});
