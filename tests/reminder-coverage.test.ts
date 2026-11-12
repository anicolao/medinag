import assert from 'node:assert/strict';
import { test } from 'node:test';
import { assessReminderCoverage } from '../web/src/reminder-coverage.ts';

test('three-minute repeats protect both complete thirty-minute windows with 22 slots', () => {
  assert.deepEqual(assessReminderCoverage(3, 10), { requiredSlots: 22, warnings: [] });
});
test('one-minute repeats warn about 62 requests rather than promising two windows', () => {
  const result = assessReminderCoverage(1, 10);
  assert.equal(result.requiredSlots, 62);
  assert.match(result.warnings[0], /62.*60/);
});
test('two-minute repeats fit, while a long snooze has a distinct warning', () => {
  assert.equal(assessReminderCoverage(2, 10).requiredSlots, 32);
  assert.equal(assessReminderCoverage(2, 10).warnings.length, 0);
  assert.match(assessReminderCoverage(3, 60).warnings[0], /beyond.*30 minutes/);
});
test('invalid intervals do not produce an infinite capacity estimate', () => {
  assert.equal(assessReminderCoverage(0, 10).warnings.length, 1);
  assert.equal(assessReminderCoverage(Number.NaN, 10).warnings.length, 1);
});
