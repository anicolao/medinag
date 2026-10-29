import assert from 'node:assert/strict';
import test from 'node:test';
import {
  escalateMedicationEvent,
  escalationIncidentId,
  isMedicationEventOverdue,
  isMedicationEventSuperseded
} from './escalation.js';

test('creates the administrator incident before marking the event escalated', async () => {
  const operations: string[] = [];

  await escalateMedicationEvent({
    ensureAdministratorIncident: async () => {
      operations.push('incident');
    },
    markMedicationEventEscalated: async () => {
      operations.push('event');
    }
  });

  assert.deepEqual(operations, ['incident', 'event']);
});

test('a later dose retires historical escalation only when that later dose is due', () => {
  const ten = new Date('2026-10-28T14:00:00Z');
  const noon = new Date('2026-10-28T16:00:00Z');
  assert.equal(isMedicationEventSuperseded(ten, noon, new Date('2026-10-28T15:59:59Z')), false);
  assert.equal(isMedicationEventSuperseded(ten, noon, noon), true);
  assert.equal(isMedicationEventSuperseded(noon, noon, noon), false);
  assert.equal(isMedicationEventSuperseded(ten, undefined, noon), false);
});

test('does not mark the event when the administrator incident cannot be created', async () => {
  let marked = false;

  await assert.rejects(escalateMedicationEvent({
    ensureAdministratorIncident: async () => {
      throw new Error('incident write failed');
    },
    markMedicationEventEscalated: async () => {
      marked = true;
    }
  }), /incident write failed/);

  assert.equal(marked, false);
});

test('uses a stable incident identifier so retries do not create duplicate alerts', () => {
  assert.equal(
    escalationIncidentId('morning_20261014'),
    'unanswered-dose-morning_20261014'
  );
});

test('becomes overdue exactly at the configured deadline', () => {
  const scheduled = new Date('2026-10-14T23:45:00.000Z');
  assert.equal(
    isMedicationEventOverdue(scheduled, 30, new Date('2026-10-15T00:14:59.999Z')),
    false
  );
  assert.equal(
    isMedicationEventOverdue(scheduled, 30, new Date('2026-10-15T00:15:00.000Z')),
    true
  );
});
