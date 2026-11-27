# Connected iPhone AlarmKit trial

This is the iOS 26.1 phone client for Alex's first server-connected trial. Use
the `MediNagAlarmPatient` scheme, not the legacy `MediNag` executable or the timer
PoC. There is no WatchConnectivity, APNs delivery, or UserNotifications repeat
queue in this executable. The old Watch app must be disabled/removed separately.

## Patient experience and real data

Open online once. Existing Firebase Google authentication and the followed
administrator are restored where available; otherwise sign in and choose a
published schedule. No account, schedule, medication or response is hardcoded.
The phone reports its time zone, and actual materialized dose occurrences arrive
through Firestore SDK listeners. Administrator-wide R and S come from the server.

The quiet screen shows only the next dose. Within 15 minutes it offers **Yes, I
did**; earlier there is no dose action. A due dose uses the actual AlarmKit alarm
UI, custom sound, and Focus/silent breakthrough under the user's alarm permission.

- **No interaction:** independent fixed-date alarms are already registered at
  T, T+R, T+2R through T+30 minutes (inclusive when on the grid). The app need
  not run, receive a delivery callback, or see a Stop/Snooze tap for these retries.
- **Stop:** save pending response state, verify the remaining retry block,
  then request deferred foreground execution to show the two equally styled
  response buttons. Stop never shifts the already-registered retry grid.
- **Snooze:** AlarmKit provides its configured countdown; the background intent
  saves a snooze response and replaces that countdown and remaining old retries
  with a block starting at the anchored T+n*S expiry, then every R for 30 minutes.
  At 08:12 with S=10 for an 08:00 dose, that is 08:20, not 08:22.
- **Yes, I did:** persist locally and cancel/read back the dose's OS alarms,
  then send the production Firestore completion transaction. Early completion
  cancels only that occurrence, not tomorrow's dose. Earlier client alerts are
  retired without falsely marking earlier medication taken.
- **Yes, I will:** persist locally and install/verify the anchored snooze block.
  Retain the existing active OS countdown as fallback until replacement succeeds.
  Then send the real snooze transaction.

Stop never means medication taken. In-app responses return to the minimal next
dose screen; the app does not forcibly quit itself. R and S are not the PoC's
one-minute constants. A snooze/follow-up cannot outlive its successor dose, and
stale actions cannot revive retired doses. Stopping a future countdown must
preserve its original deadline, not postpone the initial medication alarm.

## Smaller architecture and installed coverage

One `PatientAlarmEngine` owns one atomic file: context, actual occurrences, OS
identifiers, response outbox, and evidence. Commands are FIFO across SDK awaits;
no network operation holds that queue. A stale Firestore snapshot cannot undo
saved completion/snooze progress. Retries reuse the original tap time/version.

`PatientSession` handles setup, listeners, and network draining. It uploads as
soon as possible on real execution/connectivity opportunities. A bounded UIKit
background assertion helps finish action-triggered uploads; expiry does not
discard saved responses or hold a system action indefinitely.

Install complete 30-minute blocks, earliest dose first, within a 62-alarm budget,
leaving two slots for replacement. At R=3 each block has eleven alarms; at R=1
each has 31, so even that setting covers two full blocks. Readback verifies every
individual fixed deadline. Retain at most one currently alerting latest-dose
alarm in addition to the future slots. Actual SDK limit errors are failures,
never a fabricated successful coverage report. Partial future blocks do not
count as coverage. This is a much shorter horizon than build 21's five days:
with six daily times and R=3, five complete blocks typically cover less than a
day. Actual responses, activation,
Firestore changes and a best-effort daily background request extend coverage
from the server's materialization window. iOS does not guarantee that daily
execution slot. Without another execution opportunity the blocks are finite;
retries are not promised indefinitely. The existing backend's conservative
48-hour coverage watchdog may alert for this deliberately shorter horizon.

Fixed occurrences support early completion and anchored snooze without assuming
that stopping a recurring alarm skips only today. Initial future doses have no
pre-countdown: combining a fixed deadline with another countdown is avoided for
all initial, retry and snooze alarms. Build 21 registered a snooze for 13:05 but
the user reported its presentation around 13:10; removing the extra pre-alert
timer is a timing correction to physically validate, not a proven root cause.
Native Snooze still has its system countdown/Live Activity until the anchored
fixed-alarm block replaces it.

During upgrade, unselected far-future alarms are retired to free capacity;
selected deadlines are kept until their new configuration is verified. The
administrator's coverage record uses actual OS readback identifiers, the client
verification timestamp, and the last installed dose—not fictitious delivery.

## Reporting and remaining limits

Responses update existing `medicationEvents`, so the administrator's Today page
sees snooze/completion without a data migration. Duplicate completion is benign.
The response remains on disk until a real server acknowledgment; network loss
does not block local cancellation. Existing overdue-dose SMS behavior remains.

Append-only records at `administrators/{id}/deviceEvents/{uuid}` distinguish
registration request/verification, Stop, snooze, local response, cancellation,
observed OS state, and server acknowledgment. `observedAt` is the original client
observation; `receivedAt` is a server timestamp. Registration and OS-state
observations do not prove audible delivery.

Failure evidence and its administrator/SMS incident are created in one server
transaction before the evidence is acknowledged. Stable IDs deduplicate retries
without reusing an already-resolved incident. Reporting can be delayed offline.
The rules add only linked-patient append-only evidence permissions. The index
configuration fixes the missing `deviceCoverage.scheduledThrough` collection-
group index needed by the existing coverage watchdog.

Independent retries do not require an action handler. If a snooze handler cannot
run or fails before replacement registration, the desired new snooze block
cannot be guaranteed. Native Snooze's fallback may then be tap-relative
rather than anchored. Such failures are reported, not claimed as success. The OS
also controls an already-ringing alarm's presentation at a successor boundary;
that overlap needs physical validation. Power, permission, volume, delivery,
remote edits while suspended/offline, travel/time-zone recovery and background
execution retain platform limits. This trial is not a sole medical safety guarantee.

## Verification and Alex's trial

`npm run ios:e2e:alarm-patient` uses fresh Firebase Auth/Firestore/Functions
emulators, production rules and real web/native UI actions. It publishes three
real schedules/settings, follows on iPhone, verifies two complete 31-alarm
blocks at R=1, completes
within the early window, relaunches, and checks the returned completion and
registration/cancellation evidence on the administrator side. No medication
records or successful alarm callbacks are injected by the native test.

Local checks passed: nine Core groups, fifteen rules tests, TypeScript checking,
function tests, and build 21's connected early-completion story with 32 remaining
verified alarms and no administrator incident. A genuine registration failure
also exercised incident creation and the isolated HTTP SMS gateway; that is not
a live Twilio delivery claim. Simulator Auth needs ordinary code signing for
Keychain access; disabling signing caused a real SDK authentication failure.

Build infrastructure precedes choosing the near-future dose time. Conditions
remain capped at two seconds, without sleeps or lowered pixel tolerance. The
current-time screenshot attachments are functional diagnostic candidates, not
approved visual baselines or a full system Stop/Snooze walkthrough.

For Alex:

1. Install from **Alex Phone Trial** in TestFlight. Open online and check that the
   next dose matches the administrator's schedule. Disable the old Watch app.
2. Within 15 minutes, complete early and verify Today updates and the original
   alarm does not ring.
3. For a due dose, test Focus/silent, Stop, and leaving without responding. Check
   that the follow-up respects the server's R. Then test both response choices
   and native Snooze against S and the anchored expiry.
4. Complete offline, relaunch, reconnect and verify one server completion with no
   resurrected alarm. Physical sound, locked foregrounding, native Stop/Snooze,
   offline recovery and successor overlap still require these device checks.

The retry build must additionally be tested with **no taps at all**: lock the
phone before T and independently observe sound/system UI at T, T+R, T+2R and
through +30m. Record actual presentation times; an `alerting` SDK state is not
proof. Then complete and confirm all remaining retries stop; repeat with Snooze
and verify silence until the anchored expiry, followed by R-spaced alerts.
The 2026-11-26 16:00 device log showed an on-time daemon firing but no recorded
sound playback/presentation, despite Focus allowing it. Pre-registering retries
fixes the missing retry mechanism, not a demonstrated cure for that separate
presentation failure. No automatic real-time OS-delivery walkthrough is claimed.

Release command: `npm run ios:testflight:alarm-patient`. The first build goes to
the Alex-only internal group, not Lori's Internal build. PoC and legacy schemes
remain for comparison, but neither old alarm engine is compiled into this target.
