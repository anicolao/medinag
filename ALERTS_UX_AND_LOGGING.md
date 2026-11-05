# Patient Alerts: UX, Timing, and Logging Contract

Status: DRAFT FOR REVIEW - not implementation approval or a claim of working behavior.

Date: 2026-11-04.

## 1. The product we are agreeing to

The patient's application is a response instrument, not a dashboard.

On both the iPhone and Apple Watch its entire active-alert interaction is:

- **Yes, I did** - complete the active medication alert and stop its reminders.
- **Yes, I will** - snooze the active alert until its anchored snooze deadline.

When opened without an active alert, it shows only the next upcoming dose, as
specified in section 2.3. There is no general patient dashboard.
One response tap finishes the interaction. The response surface disappears immediately;
it must not wait for Firebase, the phone, the Watch, or a server acknowledgement.

The application, not the patient, owns timely reminders, background processing,
durable responses, synchronization, cancellation, retries, and fault reporting.
Administrators and developers receive operational information outside this
patient response surface.

Patient alerts are local OS alerts scheduled on the iPhone and Watch. They are
not remote push notifications: APNs and remote notification providers are not
part of this design. Synchronizing schedules and responses is separate from
delivering those local alerts.

This document focuses only on that experience and its proof. It is not another
general application inventory. Where earlier design proposals conflict with it,
this is the proposed replacement for patient alert behavior after review.
In particular, patient history, pending confirmation screens, and snooze measured
from the response tap are not retained. The sole non-alert view is the minimal
next-dose screen and its 15-minute early-completion action in section 2.3.

No application changes, deployments, migrations, or releases are included in
this documentation PR. Decisions explicitly marked Proposed remain for review.

## 2. Non-negotiable patient UI constraints

### 2.1 Exactly two application actions

1. The labels are exactly "Yes, I did" and "Yes, I will" on both devices.
2. Both actions have equal visual weight, readable type, adequate touch targets,
   and accessible names. Neither is preselected, the default, or visually urged.
3. No application-level third action: no Stop, Cancel, OK, Done, Retry, Refresh,
   Continue, confirmation dialog, or extra tap to finish responding.
4. No medication list, status badge, connection footer, database
   readiness, spinner, saving screen, waiting-for-confirmation screen, diagnostics,
   successful-response page, or history on the normal patient surface. The only
   dose information outside the active-alert view is section 2.3's next dose.
5. Buttons must not be greyed out because a network connection or acknowledgement
   is unavailable. Offline response must be possible for a locally known alert.
6. No follow-up "Are you sure?" or "Response saved" acknowledgement.
7. Merely viewing the alert, opening the application, dismissing the notification,
   swiping it away, or pressing an OS Stop/Dismiss control is not either response.
8. No foreground-only timer may be responsible for required alerts. Navigating
   away, responding, terminating the process, or a crash must not intentionally
   stop the reminder plan.

The application-owned response view contains only the two buttons. An OS-owned
notification may necessarily contain the app name, timestamp, a brief notification
title, navigation, or OS dismissal controls. We cannot describe those controls as
absent if the OS renders them. No added technical copy belongs in that notification.

Proposed notification title: "Medication reminder". No response count, connection
state, or diagnosis text. Approval of this title does not approve extra in-app UI.

### 2.2 One tap ends the interaction

At tap time the application durably records the response to that dose,
stops this device's current presentation, reconciles its local reminders, and
returns control without a network round trip. Persistence and local alarm changes
must be engineered as a crash-recoverable operation, not an unrecorded animation.

The user must not have to keep the app visible, open the phone after answering
on Watch, wait for a remote acknowledgement, or tap again to make the response count.
The application sends the recorded response to the other device and backend as
soon as possible, without a patient progress screen. Delivery is required, not
optional: save locally immediately, attempt synchronization immediately, and
retry until acknowledged. Exceptional conditions such as no network connectivity
may delay synchronization; resume as soon as conditions permit and log/escalate
failures under the approved policy. Never wait for synchronization to close the
response surface.

There are two distinct delivery paths to prove:

- **Notification action:** the patient taps one of the two actions directly in
  the system notification. Prefer background action handling, so the app need
  not open at all. The OS dismisses the interaction.
- **Application response surface:** opening an active notification, or opening
  the app while an alert is active, exposes only the two buttons. A tap removes
  that surface. Returning to the previous OS experience without another user
  action is the requirement; feasibility must be demonstrated on both platforms.

Removing a view, showing a blank full-screen app, or killing the process is not
automatically proof that the app "closed" from the patient's perspective.
Apple documents no graceful programmatic iOS quit API and warns against using
exit. Do not substitute private suspend APIs or a deliberate crash. If the
foreground return cannot be implemented with supported APIs, bring that precise
limitation back for approval; do not quietly add a Done button or status screen.
See [Apple's termination guidance](https://developer.apple.com/library/archive/qa/qa1561/_index.html)
and [background notification action handling](https://developer.apple.com/documentation/usernotifications/handling-notifications-and-notification-related-actions).

### 2.3 When there is no active alert

When the patient opens the application without an active alert, show only the
next upcoming scheduled dose, including when it is due. This applies equally
to phone and Watch. No list of later doses, history, status, connection details,
technical information, or additional navigation is included.

- More than 15 minutes before that dose: show the next dose only. There is no
  patient action, including no disabled response buttons.
- Within 15 minutes, including exactly 15 minutes before it: show that same next
  dose and one enabled action, "Yes, I did". The patient may take the medication
  early and tap once to complete that upcoming dose. Do not offer "Yes, I will"
  before the alert is due.
- On early completion: durably record the response, cancel that dose's initial
  alert and all repeats on both devices as soon as possible, and close the
  interaction under section 2.2. No alert is due for the completed dose when its
  scheduled time arrives. An offline response must be reconciled without reviving it.
- At its scheduled time, if not already completed: use the ordinary active-alert
  flow with the two response choices and the normal timing rules.

An already-active alert takes precedence over this no-active-alert screen; do not
introduce a selector between current and future doses. Snoozing or completing a
response still closes the interaction, rather than automatically navigating to
the next-dose screen. That screen appears on a subsequent manual opening when
there is no active alert to respond to.

Determine the 15-minute boundary from the actual dose instant, not when the app
was opened. A view left open becomes actionable at that boundary without needing
a restart or refresh. Early completion changes no other dose and does not revive
an older one. If a newer dose becomes current during a tap, retain the identity
of the dose actually presented; do not transfer the response to the newer dose.

Proposed empty-schedule case for review: if there is genuinely no next dose,
show only "No upcoming dose", with no action. A retrieval failure must not be
misrepresented as an empty schedule; operational failures remain in admin/logging
channels, not a new patient technical workflow.

First-time Google sign-in, schedule selection, permission prompts, and account
recovery are provisioning, not part of this two-button loop. They still need a
separate approved route. This document does not authorize hiding an unprovisioned
or unprotected installation behind a claim that the app is ready. Administrators
must be able to see whether provisioning/protection actually completed.

## 3. One active medication alert, never a backlog

### 3.1 Most recent due occurrence wins

An occurrence is a concrete scheduled medication time in the patient's time zone,
resolved to an absolute instant. An alert episode belongs to that occurrence.
Repeats are attempts within an episode, not separate medication tasks.

At time now, only the most recent due occurrence may own an active alert episode.
The next upcoming dose may additionally be completed early through section 2.3,
but it must not start an alert or repeat stream before its due time.
Future occurrences must not retire it before their due time. Once a later
occurrence becomes due, every earlier occurrence is permanently retired from
patient alerts, whether answered, snoozed, ignored, or never seen.

Retirement means:

- Cancel obsolete pending requests on every reachable device.
- Remove obsolete delivered notifications where the OS permits it.
- Never schedule another old repeat or snooze expiry.
- Never expose old buttons when an old notification is tapped.
- Never revive old work during cache replay, reconnect, restart, upgrade,
  timezone recalculation, schedule edit, or out-of-order message delivery.
- Preserve the historical audit result as unconfirmed/superseded, not taken.

If the newest occurrence is completed, there are zero active episodes until
the next scheduled time. Do not search backward for the newest *unanswered*
occurrence. Completion of today's alert must never reveal yesterday's alert.
If the next occurrence was completed early, its arrival still supersedes every
earlier occurrence, but starts no alert of its own. Its completed state must be
retained as a barrier against historical replay.

Both devices represent the same one active episode. They do not each own an
independent medication obligation. Earlier requirements to alert on both devices
and accept a response on either remain the target; delivery routing must be
tested rather than inferred from one phone notification.

### 3.2 One scheduled alert per time

A schedule allows only one alert at a given time. The administrator cannot save
or publish a second alert for the same time on the same scheduled day. This rule
is enforced in the administrator UI and backend, including when editing alerts.
There is no grouping, per-medication paging, or multiple-dose response flow.

### Schedule changes

Use a monotonic episode/version identity, not client arrival order, to select the
newest occurrence. A delayed old message must not become current merely because
it arrived last. An old response is bound to its original episode; never apply
it to a new dose that appeared while the patient was tapping.

Proposed schedule-edit policy: future changes affect future episodes. An active
episode's repeat/snooze configuration and origin remain frozen. Pause, deletion,
or explicit withdrawal retires it; resume does not resurrect past work. A change
must not move its origin to now or extend an old episode beyond a known successor.
Revisions that remove/change a successor require a reviewed boundary policy,
not an accidental extension from a stale cache.

### 3.3 Example: yesterday is gone

Yesterday's 8 AM medication was never answered. Today's 8 AM time arrives.
Only today's alert may notify or accept a response. The patient taps "Yes, I did"
today. All current reminders stop. Yesterday's missed dose remains only in the
audit/admin history and must never reappear on either device.

This rule also applies to two doses on the same day: noon replaces an unanswered
10 AM episode at noon. No old request may intentionally be registered at or after
that known replacement boundary.

## 4. Exact reminder and snooze timing

### 4.1 Administrator settings

The administrator can set and save:

- **Repeat interval R:** how often an unanswered alert is retried; example 3 minutes.
- **Snooze interval S:** length of a response window measured from its original
  alert deadline; example 10 minutes.

R and S are set once per administrator and apply to all of that administrator's
schedules. There are no per-schedule or per-dose overrides. Each administrator
controls their own settings independently of other administrators.

Neither value may be hardcoded in a test or native client as hidden product policy.
Both must flow from the saved web configuration through the real backend to
both devices. Proposed validation is positive durations with R < S and values
the selected notification mechanism can actually support. Exact ranges still
need approval. The examples here
are inputs, not a mandate that every schedule use 3 and 10.

Time is interpreted in the patient's time zone, not the administrator's.
Calendar/DST resolution must produce one stable instant for each occurrence;
the exact DST policy is a separate review item, not an excuse for duplicate doses.
Intervals use elapsed duration, not wall-clock string subtraction.

### 4.2 Definitions

- T: original medication occurrence time.
- A: scheduled origin of the current repeat stream. Initially A = T; after a
  snooze expires, A is that snooze's scheduled expiry time.
- R: administrator's repeat interval applied to this episode.
- S: administrator's snooze interval applied to this episode.
- P: actual time the patient tapped a response.
- D: next snooze boundary strictly after P on the grid T + S, T + 2S, T + 3S, etc.
- C: next newer medication occurrence time, or an explicit valid coverage boundary.

The origin is the intended scheduled deadline, not the time the app happens to
run, the time a schedule was synchronized, the time of a repeated notification, or the
first time we obtained delivery evidence. A late alert must not reset history.

### 4.3 Before a response

The first alert is due at T. Until an effective response, repeats are due at
A + R, A + 2R, A + 3R, and so on, strictly before C.
Ignoring or dismissing an alert, reopening the app, or a failed network operation
does not move that cadence. Retrying failed scheduling must not quietly create
an origin of now.

Do not replay all missed deadlines in a burst if a device reconnects late.
Record missed/unknown attempts, consider only the current episode, and schedule
the next legitimate boundary. Proposed catch-up: if an active episode is already
overdue, one immediate current reminder is allowed, followed by the original
cadence, not a historical flood. Whether that immediate catch-up is desired is
an explicit review question. It never counts as on-time delivery of old attempts.

### 4.4 Yes, I did

This completes the episode. Stop current presentation, cancel all remaining
repeat/snooze requests for it, and propagate that decision to the other device
and backend. It is final for that episode; delayed messages cannot undo it.
No older episode becomes active as a consequence.

### 4.5 Yes, I will: the central correction

Snooze until the next boundary on the grid anchored to T, not P + S:

**D = T + (floor((P - T) / S) + 1) * S.**

For an 8:00 dose with S = 10 minutes, the grid is 8:10, 8:20, 8:30, and so on,
regardless of whether earlier alerts were ignored or snoozed. For a response
before 8:10, this is the original 8:10 deadline.

Cancel the current stream's remaining ordinary repeats before D. If D < C and the episode
is still incomplete, the next alert is due at D. An action does not earn a fresh
S minutes merely because the patient waited before responding.

Example with R = 3 minutes and S = 10 minutes:

| Time | Event | Required consequence |
| --- | --- | --- |
| 8:00 | Original alert, A = 8:00 | Response window began at 8:00 |
| 8:03 | Ignored alert repeats | Same episode and same A |
| 8:03 | Patient taps Yes, I will | Snooze ends at 8:10, leaving 7 minutes |
| 8:06, 8:09 | Former repeat slots | Cancelled by the effective snooze |
| 8:10 | Snooze expires unanswered | Actual new OS alert; never a fabricated screenshot |

A tap at 8:04 leaves six minutes. A tap at 8:09:30 leaves thirty seconds.
The answer must not be rounded into another ten minutes. If a newer occurrence
is due at 8:08, retirement at 8:08 wins; the old 8:10 snooze must never fire.

### 4.6 Subsequent snoozes and late taps

The snooze grid always remains anchored to the original medication time T.
Missing a window does not forfeit the ability to snooze to the next boundary.

1. Ignore the 8:00 alert and its 8:03, 8:06, and 8:09 repeats. At 8:12, tap
   Yes, I will: the next alert is due at **8:20**, leaving eight minutes.
   The ordinary 8:15 and 8:18 repeats are cancelled. It is not due at 8:15 or 8:22.
2. If instead the patient snoozed before 8:10, its actual expiry alert is due at
   8:10. Ignoring that gives repeats at 8:13, 8:16, etc. A tap at 8:13 snoozes
   until 8:20, not 8:23.
3. With no response, R still controls repeats; crossing a snooze-grid boundary
   alone does not create an additional alert or alter the repeat cadence.
4. A tap exactly at 8:10 snoozes to 8:20; exactly at 8:20 snoozes to 8:30.
   The selected deadline is always strictly after the tap, never an immediate loop.
5. Save D with the original response. Duplicate callbacks, retransmissions, and
   delayed synchronization reuse that saved deadline; they do not recalculate
   from retry or server receipt time or extend an already-recorded snooze.
6. At a legitimate snooze expiry, that scheduled expiry becomes A for subsequent
   R-spaced repeats. It does not move the snooze grid anchored to T.
7. Reaching C retires the episode regardless of repeat or snooze state.

## 5. Patient journeys to review

These are target acceptance stories, not reports of passing tests.
Every story applies to both phone and Watch unless a device-specific branch says
otherwise. The visible endpoint of every response is the OS/previous experience,
not a saving page. Nonvisual evidence belongs in the test report and admin logs.

### J01 - Timely first alert, Yes, I did

Start: provisioned patient, saved real schedule, supported permissions/settings,
devices available, apps not running in the foreground. At T, observe the actual
OS alert. Tap Yes, I did directly in its actions. The presentation disappears
without another tap. Record local intent before process loss, real completion,
other-device cancellation, and absence of later alerts for that episode.
Repeat with app foregrounded and by opening the notification then using the
application's two-button surface. Capture every system screen and tap.

### J02 - Ignore, repeat, anchored snooze

Start with R = 3 and S = 10 configured through the administrator UI. Ignore the
first actual alert at 8:00. Observe the actual repeat at 8:03; tap Yes, I will.
The interaction ends. No 8:06 or 8:09 alert is allowed. An actual alert is due at
8:10 with apps inactive, not at 8:13. Respond Yes, I did; all remaining alerts stop.
Repeat with a non-integer tap time, e.g. 8:04:20 -> 8:10.

### J03 - Ignore/dismiss without responding

Swipe away, clear, open without answering, navigate away, lock the phone, and use
any system-owned dismiss control in separate runs. None records a medication
response. Repeats continue on the approved cadence. The test must observe actual
system alerts, not merely a list of pending requests or an in-app timer firing.
Do not promise that the OS prevents a human dismissing or ignoring a notification.

### J04 - Snooze expires, next cycle, late snooze

Exercise every boundary in section 4.6: before D, exactly D, after D, duplicate
tap, retry, and response from a stale delivered notification. Explicitly ignore
the 8:00 dose until 8:12, tap Yes, I will, and observe the next actual alert at
8:20, with none at 8:15 or 8:18. Verify the snooze grid never moves from T and
that retrying the response cannot extend its saved D. No patient error screen.

### J05 - Only the newest dose, then no active work

Leave yesterday and an earlier same-day episode unanswered. When the latest
episode becomes due, only it alerts. Respond Yes, I did. Reopen both apps,
restart them, reconnect an old cache, and deliver delayed messages. No historical
alert or response surface returns. Repeat when the earlier episode was snoozed
past the newer due time and when the newer episode was already completed elsewhere.

### J06 - Respond on either device

Establish actual phone and Watch delivery under the approved routing design.
Respond on one; close its interaction immediately. On synchronization, the other
device removes obsolete alerts and applies the same completion or anchored D.
Double taps/retries do not create extra actions. Completion wins over a later
stale snooze for the same episode. A disconnected device cannot know a remote
response instantly: document and measure that propagation limit rather than
claiming simultaneous cancellation. No connectivity information reaches the patient UI.

### J07 - Offline, crash, and uncertain acknowledgement

Respond with the network unavailable, phone absent from Watch, or backend slow.
The local response is durable and the surface closes without a spinner.

In separate crash-recovery tests, deliberately stop and relaunch the iPhone or
Watch application process at each point below. This does not mean rebooting the
device, clearing its saved data, or restarting Firebase. Where Watch sends its
response through the phone, also interrupt the phone app while it forwards the
saved response. Preserve real writes and communication; do not fake a successful
save or acknowledgement to reach a test checkpoint.

| Interruption point | What is happening when the app is stopped | Required result after relaunch |
| --- | --- | --- |
| Before the tap is saved locally | The patient tapped, but no durable record exists yet | Do not invent a saved response. The alert remains unanswered and its reminders continue. This is a real failure to retain the tap, not successful recovery; log/escalate it if observable. |
| After the tap is saved locally | The durable record exists, but subsequent work may not have started | Recover that exact response and continue processing it without another patient tap. |
| While changing local notifications | The app is removing completion reminders or replacing them with the snooze deadline | Reconcile the actual OS requests with the saved response; finish the cancellation or snooze without creating duplicates. |
| While sending the response | The response is in transit to the backend, possibly through the phone; the sender may not know whether it arrived | Retry the same saved response until its outcome is known; it must take effect only once. |
| Immediately before or after the backend saves it | Stop the client app while the real backend write is being processed; the backend itself keeps running | Determine whether the write completed, and retry safely if necessary. A completed write must not become a second response. |
| After the backend saves it but before confirmation reaches the app | The write succeeded, but the acknowledgement was lost or the receiving app stopped | Discover the existing result or resend the same response safely. Do not treat missing confirmation as proof that the write failed. |

For both Yes, I did and Yes, I will, verify the final local notifications, real
backend result, and other device's state. A completion must stay completed. A
recovered snooze uses the deadline saved with the original tap, never a fresh
interval from relaunch, reconnect, or retry time. No patient saving/retry screen
or second confirmation tap is introduced.

If local persistence or scheduling fails, record a critical fault and notify the
administrator where possible; do not pretend the tap was durably saved.
The recovery design for this rare failure must be approved without adding a
patient technical workflow or silently losing the response.

### J08 - Old notification or simultaneous response race

A newer dose becomes due while an old surface is open. An old notification is
then tapped, or both devices answer concurrently. Bind every action to the
episode and cycle actually presented; never mark the new dose taken by accident.
Reject stale scheduling resurrection. Proposed: a delayed historical action can
be recorded as historical intent, but cannot activate, snooze, or clear a newer
episode. Contradictory actions for one episode need a deterministic audited
policy; proposed completion is terminal and duplicate snoozes share D.

### J09 - Configuration really controls timing

Change R and S on the administrator website, using different valid values from
the examples. Observe the saved revision through the real backend and native
clients. Verify future episodes across all of that administrator's schedules use
those same values, with no per-schedule overrides. Verify another administrator's
settings and schedules are unaffected. Attempt invalid settings
and simultaneous edits. Confirm that an existing cycle does not change origin
or deadline mid-response unless such a change was explicitly approved.
Try adding or editing a second alert to the same time on the same scheduled day.
The administrator UI rejects the conflict, and the backend rejects it as well;
no duplicate alert is saved or published. Distinct times remain valid.

### J10 - Delivery late, missing, or not observable

Induce a real scheduling rejection, queue exhaustion, revoked permission, device
power-off, app termination, network outage, late schedule synchronization, and absent
delivery observation as separate cases. Keep the patient's interface minimal.
Logs/admin reports distinguish proven failure from unavailable evidence.
Verify administrator incident and SMS paths, recovery, no backfill storm, and
that a late request is never counted as an on-time alert.

### J11 - Next dose, early completion, and provisioning boundary

With no active alert, manually open each app. Show only the next upcoming dose.
More than 15 minutes before it, show no actions. Check just outside the boundary,
exactly 15 minutes before it, and just inside it: at/inside the boundary there is
only "Yes, I did", never a snooze action. Leave the view open across the boundary
and verify the action appears without a refresh or restart.

Tap Yes, I did once before the due time. The response is saved locally, the
interaction closes immediately, and synchronization starts as soon as possible.
Verify the real backend completion and cancellation on both devices. Advance to
the original dose time and later repeat slots: no alert for the completed dose
may occur. No older unanswered episode becomes active instead. Exercise offline
early completion, reconnect, restart, and stale-message delivery as separate cases.

Do not automatically navigate to this screen after a response. On a subsequent
manual launch, show the next actual upcoming dose, not the completed one. Verify
no-next-dose handling separately, and that an active alert takes precedence.
Separately verify that initial setup and recovery actually enable scheduled
alerts, and that failures are reported to the administrator. These checks must
not add status or technical information to the patient's response/next-dose screens.

## 6. Reliability requirements and limits we must not hide

The goal is no missed required alert in the supported operating conditions,
persistent reminders until response or supersession, and no silent loss.
It is not honest to promise that software can force a human to notice, hear,
or answer, or that a powered-off/uninstalled/unauthorized device must alert.

The system must maintain a ledger of every expected alert attempt independently
of whether a running patient application reports it. A stopped/crashed client
cannot be the sole detector of its own failure. A coverage monitor must identify
unregistered, expired, stale, and unobserved protection with truthful categories.
Actual failure or loss of approved protection raises a durable administrator
incident and SMS attempt through the existing escalation policy; a patient-only
warning is not sufficient. Administrator incident creation precedes marking an
event escalated, with retries/deduplication if provider submission fails.

Do not treat isReachable = false as a disconnected/broken Watch. Verify required
communication failures and actual protection coverage. Do not send the
administrator an SMS merely because the app is idle or the phone and Watch are
not actively communicating; that can be normal while required alerts remain
scheduled and working. Send an SMS for an actual failure, such as being unable
to schedule required alerts, not ordinary inactivity.
Lack of delivery telemetry alone is not proof of failed delivery, but unresolved
uncertainty must remain visible to the administrator and be handled under an
approved policy, never greenwashed as successful delivery.

Specific proof obligations:

- First alerts and repeats must be owned by a mechanism that functions when
  the application is not foregrounded. A Firestore listener alone is not a
  wake/delivery guarantee. Daily background refresh must not be assumed punctual.
- A finite pending-notification queue must not quietly run dry. Demonstrate its
  capacity, coverage end, renewal mechanism, and independent exhaustion detection
  for the maximum approved repeat duration. A few minutes of success do not prove
  a day of protection. Infinite unattended repeating cannot be asserted from a
  finite batch and an assumed background wake.
- Phone-targeted notifications normally route to one of phone/Watch under OS
  rules. Both-device alerting requires a separately demonstrated architecture,
  including unlocked phone, locked phone with worn Watch, and Watch not worn.
- Sound, haptics, Focus, mute, permission revocation, locked devices, restart,
  low power, and the exact TestFlight build must be checked on physical hardware.
- Critical Alert sound privileges require Apple's entitlement and user consent.
  They do not themselves prove a human heard the alert or solved queue renewal.
- System-dismiss controls may remain. Dismissal is not a response; persistence
  means future scheduled attempts continue, not that OS dismissal is impossible.

These are architecture acceptance gates, not permission to add status to the
patient interface or quietly relax the two-button/one-tap requirement.

## 7. Local alert logging: what it must prove, and what it cannot

This section concerns only what happens on the phone and Watch: local scheduling,
OS presentation evidence, patient taps, and local cancellation/snooze behavior.
It does not specify server-side processing, push delivery, or SMS-provider logs.

### 7.1 Separate the evidence levels

For each expected attempt, record the strongest actual evidence and retain gaps:

| Evidence | It establishes | It does not establish |
| --- | --- | --- |
| Expected local alert deadline | A reminder was required | The OS received a request |
| Local scheduling attempted | App tried to register an alert | OS accepted it |
| Local OS registration accepted | OS accepted a request | It presented or sounded at deadline |
| Pending request inventory | Request existed when queried | It fired or will necessarily fire |
| Foreground presentation callback | That device reported a presentation opportunity | Audible output or background delivery |
| Delivered-notification observation | OS reports an item present in Notification Center | Complete delivery history or human attention |
| System UI captured on hardware | That presentation was visible in the capture | All alerts on every installation were visible |
| Audio/haptic observation | Output was observed in that device test | The patient perceived it |
| Action callback / durable response | A named action was invoked/recorded | Medication was actually ingested |

Apple's delivered-notification API returns items still in Notification Center,
not a universal receipt feed. An absent item can have been dismissed or handled;
it is not sufficient to declare it never delivered. Likewise, disappearing from
pending requests is not a delivery acknowledgement. An app asleep at the time
may have no callback for that presentation.

Therefore the desired "prove every alert delivered on time" is a requirement
to pursue, not an already available universal production capability. If the
selected OS mechanism cannot expose a receipt, mark delivery as **unknown**,
retain scheduled/deadline evidence and obtain physical test evidence. Do not
invent a delivered log at the planned time. If universal receipt is a hard
release requirement, the architecture is blocked until a suitable mechanism is
demonstrated or the requirement is explicitly revised.

### 7.2 Correlation and fields

Use structured, versioned, append-only local audit events. They must correlate
the schedule received by the device -> expected local deadline -> OS request ->
actual OS evidence -> patient tap -> local save -> cancellation or snooze.
No developer console session should be necessary to reconstruct a patient's day.

Required fields, where applicable:

- unique audit event ID; type; schema version; source/build/OS version;
- pseudonymous patient/administrator IDs, installation and device role;
- schedule revision, episode ID, cycle ID, attempt ID, native OS request ID;
- patient zone, T, A, R, S, D, successor/retirement boundary C;
- intended deadline; local registration start and OS acceptance/rejection timestamps;
- observation type, source timestamp, collection timestamp and evidence reference;
- response command ID, exact action, presented episode/cycle/attempt ID, P;
- local durable-save and surface-dismiss timestamps, cancellation/replacement
  acknowledgement, and locally observed application of a response from the other device;
- effective result, duplicate/stale/rejected reason, failure code, retry identity;
- local fault/report ID and recovery linkage;
- clock source, measured offset/uncertainty, logical test clock mapping, sequence
  number and device monotonic timing where available.

Do not record access tokens, credentials, or unnecessary medication
details in diagnostic logs. Restrict log access. Proposed retention/export policy
must be reviewed; this document does not authorize publicly readable health logs.

### 7.3 Named audit milestones

At minimum distinguish:

1. schedule received on this device / episode current / superseded or completed;
2. alert expected / registration attempted / accepted or rejected / coverage verified;
3. presentation observed / delivered item observed / evidence unavailable;
4. notification opened or dismissed, where actually observable;
5. response tapped / saved locally / local presentation dismissed;
6. local repeat cancelled / snooze scheduled / reconciliation failed;
7. response from the other device applied locally / obsolete requests removed;
8. local deadline audit passed, failed, or unverified / fault recorded / recovery observed.

OS acceptance of a local request is not proof of presentation. Retries retain
causal IDs and do not erase earlier failed attempts. No log may claim delivery
merely because the registration API succeeded.

### 7.4 Latency and missing-evidence reports

For every episode and attempt, administrators/developers need a trace showing:

- registration lead time: intended deadline minus registration acknowledgement;
- observed delivery lateness: actual supported presentation timestamp minus
  intended deadline, with source and uncertainty;
- response latency from original cycle origin: P - A;
- response latency from medication time: P - T;
- response latency from a specific observed presentation, only if that
  presentation and response can actually be correlated;
- tap-to-local-durable-save, tap-to-surface-dismiss, and tap-to-local cancellation
  or snooze registration; receipt-to-local-cancellation for a response from the other device;
- all expected attempts, their evidence category, overdue unknowns/failures,
  suppressions due to snooze/completion/supersession, and coverage end.

If the exact presentation time is unavailable, do not call P - scheduledDeadline
"time since the user saw it". If the tapped notification's attempt is unknown,
report that, not a guess based on the latest pending ID. Retain device tap time
separately from later log collection/upload time. Offline and skewed clocks require explicit
uncertainty; a negative or hours-long apparent duration is investigated, not hidden.

The report must let us investigate the observed hours-late/missing alerts: was
the schedule received late, the alert registered late or rejected by the OS,
presented late, suppressed by settings, superseded, or simply not observable?
"Everything succeeded" based only on local OS registration is unacceptable.

## 8. E2E evidence and acceptance

### 8.1 Real flow, not a performance of the desired behavior

Follow [E2E_GUIDE.md](E2E_GUIDE.md) for real Auth/Firestore emulators and enabled
rules, zero-pixel comparison, generated ordered walkthroughs, event-driven waits,
and the two-second automated condition timeout. Its older patient screen inventory
must be reconciled with this contract after approval, not treated as permission
to keep dashboards or status screens.

Create identities/relationships and schedule/configuration through approved real
user flows. The actual backend materializes occurrences. Native clients observe
the same real IDs, schedule through the production notification implementation,
and respond through the production data path. No encoded event arrays, fake
delivered callbacks, injected Watch snapshots, in-process repository substitutes,
or Admin SDK data seeding masquerading as a user journey.

Time acceleration is allowed only through a coherent, documented clock boundary
shared by the relevant scheduler/backend/clients and mapped to actual OS triggers.
It may change when time passes; it must not replace notification delivery or
response handling. If the OS clock cannot be advanced safely, map a logical
deadline to a near-future real trigger using the same production request path,
and label precisely what timing was accelerated. Such a run does not prove a
ten-minute wall-clock timer, calendar/DST behavior, or unattended endurance.
Separate real-time hardware/soak evidence is required for those properties.

Tests await causally related OS UI, callback, real snapshot, or log-stream events.
No arbitrary sleeps, delayed success screenshots, fixed polling loops, or increased
timeouts. A two-second condition limit is not permission to replace an unobserved
OS event with an assertion that the request was merely queued. Long-duration
hardware observation must be explicitly labeled separate evidence, not a relaxed
automated E2E test.

### 8.2 Minimum evidence matrix

| Story | Required proof beyond screenshots |
| --- | --- |
| J01 | Real first OS presentation, response, immediate closure, committed result and cancellation |
| J02 | Actual initial/repeat/snooze-expiry notifications, anchored D, suppressed intermediate slots |
| J03 | Dismissal is not a response; actual later repeats with apps inactive |
| J04 | Original-time snooze grid; 8:12 tap -> 8:20 alert; exact-boundary and retry behavior |
| J05 | Newest-episode selection including completed newest; no old queued/delivered replay |
| J06 | Physical routing matrix, either-device action, one result, measured propagation/cancellation |
| J07 | Real transport partition/process termination, durable intent, no network-dependent UI closure |
| J08 | Version/identity race outcomes; old action never affects new episode |
| J09 | Administrator-wide R/S write and downstream timing across their schedules; isolation from other administrators; rejection of conflicting scheduled alert times |
| J10 | Genuine fault, honest evidence category, incident and captured SMS request, bounded recovery |
| J11 | Next-dose-only UI; exact 15-minute boundary; real early completion, closure and cancellation; no historical replay; separate provisioning proof |

Every walkthrough records source SHA, build, environment, settings, clock mapping,
actual episode/request IDs and all screen transitions/taps. Capture both buttons
with equal weight, OS dismissal controls, no patient status UI, and the return
after tapping. Do not crop out errors or pretend a blank app is the home screen.
Do not update old visual baselines until the revised UX is explicitly approved.

### 8.3 Timing criteria to approve before implementation

"Timely" must become measured budgets, not subjective screenshots.
Proposed budgets for controlled, supported conditions:

- Intended trigger timestamp equals the approved deadline at supported resolution;
  no rounding into the following minute or timer based on tap time.
- On-time actual presentation: within 5 seconds after the deadline, never
  intentionally before it. This is a proposed hardware product target to prove,
  not a claim the OS guarantees it or an extension of E2E condition timeouts.
- Tap-to-local durable intent and removal of response surface: within 250 ms,
  with no network dependency. Supported OS transition animation is separately
  recorded; it does not justify a saving screen.
- Connected response propagation/cancellation and backend data assertions:
  within the guide's 2-second condition budget when their causal event is due.
- Independent missing-protection/deadline evaluation: within 60 seconds; incident
  creation and provider submission latency are measured separately. Exact SMS
  dispatch budget, unknown-delivery escalation threshold, and deduplication need
  approval. A 60-second evaluation does not make an hours-late alert acceptable.

Failures against these budgets remain failures. If a platform cannot meet a
budget, present the evidence and seek a changed requirement before release.

### 8.4 What passing tests can and cannot claim

We can demonstrate no missing expected attempts in a specified test run, correct
cadence/cancellation, crash recovery, honest logging, real OS presentation under
tested settings, and a monitor that finds injected real failures.
We cannot prove from finite E2E runs that an alert can never be missed on any
future device, that a person can never ignore it, or that every OS presentation
produces a production receipt. Release claims must name the operating conditions,
coverage duration, evidence gaps, and fault response. An unproven hard requirement
remains a blocker, not a passing test with an optimistic caption.

## 9. Focused review checklist

Confirm the core requirements first:

- [ ] Only two equally weighted actions on phone and Watch; no patient dashboard,
      status, readiness, confirmation, history, or technical workflow.
- [ ] One tap ends the interaction without awaiting network acknowledgement.
- [ ] Without an active alert, show only the next upcoming dose; at/within 15
      minutes offer only Yes, I did for early completion. Earlier than that, no action.
- [ ] Record responses immediately and synchronize as soon as possible, retrying
      until acknowledged; exceptional connectivity delays do not keep the UI open.
- [ ] Timely original alerts and administrator-wide R/S applying to all their
      schedules without overrides; repeat does not reset origin.
- [ ] 8:03 snooze of an 8:00 alert with S = 10 ends at 8:10, not 8:13.
- [ ] 8:12 snooze of that same dose ends at 8:20, not the next R-spaced repeat
      or ten minutes after the tap; the snooze grid stays anchored to 8:00.
- [ ] Only the newest due occurrence is ever active; completion never reveals old work.
- [ ] A schedule allows only one alert at a given time; duplicate times cannot
      be saved or published. There is no simultaneous-dose grouping flow.
- [ ] Respond on either device; do not add patient synchronization duties.
- [ ] Honest per-attempt logs, response latency and administrator failure handling.

Resolve these narrow ambiguities rather than inventing a broader product:

1. Approve the supported R/S ranges and freeze-on-active policy; their
   administrator-wide scope is settled.
2. Define acceptable foreground close behavior after a response if the OS cannot
   return to the prior experience programmatically; keep the one-tap goal visible.
   Approve the proposed no-next-dose empty state separately; manual launch with
   a next dose now has the defined minimal screen, not a blank/auto-close policy.
3. Approve a separate provisioning/recovery route without a normal patient dashboard.
4. Decide immediate current catch-up versus next cadence slot after late startup,
   and first enrollment's prospective protection boundary (no invented old failure).
5. Approve concurrency and stale-action policy, especially a late offline response.
6. Approve the measurable budgets, unknown-delivery handling, SMS thresholds and
   log retention/access. Does unknown presentation evidence block release?
7. Approve required both-device routing/coverage duration after physical proof,
   plus the DST and schedule-edit successor-boundary policies.

After approval, implement/prove the small real vertical slice first: actual alert
on the devices -> one tap -> immediate end of interaction -> durable result ->
anchored snooze or cancellation -> no old alerts. Then expand fault/race coverage.
Do not start by rebuilding a patient dashboard or producing another simulated
walkthrough that cannot establish notification behavior.

## 10. Platform references

These constrain claims; they do not certify our current code:

- [Notification actions](https://developer.apple.com/documentation/usernotifications/handling-notifications-and-notification-related-actions):
  background action handling can avoid bringing the app to the foreground.
- [iOS termination guidance](https://developer.apple.com/library/archive/qa/qa1561/_index.html):
  archived Apple guidance documents no graceful application quit API; a deliberate
  exit is not an acceptable implementation of the desired interaction.
- [Delivered-notification inventory](https://developer.apple.com/documentation/usernotifications/unusernotificationcenter/getdeliverednotifications%28completionhandler%3A%29):
  lists notifications still present, not a complete per-alert receipt history.
- [Notification forwarding](https://developer.apple.com/documentation/watchos-apps/taking-advantage-of-notification-forwarding):
  normal phone-targeted notifications route to phone or Watch; Watch-local ones
  stay on Watch. Both-device delivery requires explicit architectural proof.
- [Critical Alerts entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.usernotifications.critical-alerts):
  special sound behavior requires entitlement approval and authorization, not
  merely a TestFlight build or an urgency setting in our own database.
