# Independent phone and Watch reminders

Build **0.1.0 (14)** has known historical-reminder flooding and stuck-response
bugs. The fixes below are in source, but the replacement TestFlight upload is
blocked by Apple's `FORBIDDEN_ERROR.PLA_NOT_ACCEPTED`: the Account Holder must
accept the updated Program License Agreement. No build 15 has been uploaded.
Local verification: 24 native unit tests, eight portable core checks, and nine
backend tests pass. The backend next-dose escalation cutoff is deployed. The
connected native walkthrough and physical dual-device delivery are still not
approved evidence. No deadlines were extended or failed captures promoted to
baselines.

The latest paired run reached the Watch's real dose and response controls, but
timed out awaiting the server-confirmed snooze within two seconds. That remaining
acknowledgement failure must be diagnosed; passing unit tests is not a substitute
for a passing connected walkthrough.

## Behavior

Both apps register regular, actionable local notifications with the operating
system. Each offers `Yes, I did` and `Yes, I will`. There is no AlarmKit Stop
button. Upgrading reconciles and cancels the old AlarmKit alarms.

Ignoring or dismissing an alert does not answer the dose. Follow-ups are
pre-scheduled at three-minute intervals; delivery does not require the app to
remain running. `Yes, I did` completes the real Firestore event and removes its
remaining alerts. `Yes, I will` replaces the sequence with one beginning at the
administrator's configured snooze deadline. The administrator's escalation
threshold does not silently disable patient reminders.

At the next scheduled medication time across the plan, earlier unanswered doses
stop nagging. Simultaneous medications remain in the same dose group. A later
completed dose still retires earlier doses at its scheduled time, not earlier.
Every queued follow-up is bounded by that cutoff, even with the apps terminated.
Old records remain unanswered in history; this never fabricates a completion.
The backend likewise stops creating new overdue escalations for retired doses.

The phone owns authentication and transactional writes. The Watch owns a separate
notification queue from its last real synchronized snapshot. Watch responses use
interactive WatchConnectivity plus a persisted background transfer. A duplicate
or stale response cannot increment snooze twice. Neither device claims success
until the server transaction is acknowledged. A disconnected Watch response
remains pending until confirmation arrives or its dose is superseded. Both
interactive and background deliveries carry matching acknowledgements. A
definitive rejection clears the outbox; a transient failure keeps the original
command available for an idempotent retry. Actual interactive operations have a
five-second deadline; ordinary refreshes and queued responses cannot permanently
disable the response buttons. Errors are shown rather than hidden behind a
generic pending message.
Transient phone startup/reconnection snapshots cannot erase a ready Watch cache
or its queued alerts. Only a confirmed unlink/sign-out can clear it; a native
regression test verifies this distinction and older cached-payload decoding.

The Watch shows only the medication and next reminder time. At strictly less
than 15 minutes before that time, or when overdue, it also shows the two equally
weighted responses. Completed history, administrator headings, readiness panels,
refresh controls, and scrolling have been removed. Necessary connection/failure
messages remain.

Normal `WCSession.isReachable == false` is not labeled "iPhone disconnected": it
does not prevent background transfers. Transient transport errors are logged and
retried on session signals; persistent actual transfer errors (three attempts
over five minutes) or non-retryable errors still alert the administrator.
Watch notification registration errors have their own incident code/message.
Pending-count verification excludes deadlines that elapsed during registration,
without claiming those alerts were delivered. Missing future requests still fail.

## Important limits — not production guarantees

- Each device registers at most 60 pending alerts in chronological order.
  Far-future initial doses cannot crowd out near-term follow-ups. This is
  finite coverage, not an unlimited offline nag loop. Refreshing/reconnecting
  replenishes it. With one unfinished dose and no other doses, 60 requests cover
  about three hours of alerts. Multiple unfinished doses shorten that window.
- The phone reports the earliest omitted alert as its coverage deadline, not the
  last future dose. Existing backend coverage monitoring/SMS remains enabled;
  its 48-hour warning threshold will flag this shorter coverage. Background
  execution is opportunistic and cannot guarantee indefinite renewal.
- Each device must receive a changed schedule. An offline Watch cannot learn
  about a new dose or cancellation until WatchConnectivity delivers it. One
  device answering cannot instantly silence a disconnected device.
- The phone uses the bundled custom sound. The Watch uses its system sound.
  Critical Alerts are not enabled: notification permission, Silent Mode, Focus,
  volume and system delivery policies still apply.
- Independent queues do not by themselves disable Apple's forwarding policy.
  Simultaneous audible alerts must be verified on physical devices; Simulator
  screenshots and successful queue registration cannot prove them.

## Configure and try on physical devices

1. Install the same new TestFlight build on iPhone and Watch. Open both apps,
   sign into the phone, follow the schedule, and allow notifications on both.
2. In the iPhone Watch app, inspect **Notifications → MediNag**. Disable
   **Mirror iPhone Alerts From** if available, while keeping the Watch app's own
   notification permission enabled. **Do not select Notifications Off if it
   disables the Watch's own alerts.** If these permissions cannot be configured
   independently, report that result: dual-device routing is not established.
3. Temporarily turn off Focus/Silent Mode, turn up both volumes, and wear/unlock
   the Watch. Publish a dose several minutes ahead using the dashboard.
4. With the dose at least 15 minutes away, the Watch must show only its name and
   time. Inside 15 minutes, both response buttons must fit without scrolling.
5. Background both apps and lock the phone. At the dose time, check for an alert
   on **each** device. Expand the notification to check both custom actions.
   Record a failure if the Watch alert suppresses the phone alert.
6. Dismiss without answering. At the next three-minute boundary, check that both
   devices alert again. Repeat once with the apps terminated.
7. Choose `Yes, I will` on the Watch notification. Confirm snoozed status on the
   dashboard. Neither device should nag during the configured snooze; both should
   alert again at expiry. Repeat with the response made on the phone instead.
8. Choose `Yes, I did` on either device. Confirm dashboard completion and the
   Watch advancing to the next unfinished dose. Neither device should alert for
   the completed dose at the next three-minute boundary.
9. Repeat off-wrist and with the phone app terminated. Separately disconnect the
   devices, respond on Watch, and verify pending confirmation rather than false
   success. Reconnect and confirm exactly one persisted response.
10. Publish two dose times a few minutes apart. Ignore the first; when the second
    becomes due, the first must stop nagging on both devices and disappear from
    the Watch's current-dose view, without being recorded as taken. Repeat with
    the later dose completed early. Its scheduled time still ends the old window.
11. Leave both apps quiescent: no routine "iPhone disconnected" footer or sync
    SMS should appear solely because immediate messaging is unavailable. A real
    future-registration failure must still appear and alert the administrator.

Automated tests use the same planner and UserNotifications APIs. Native unit
tests verify planning, strict response-window boundaries, response-version
protection and actual registered action categories. Connected walkthroughs must
verify Firebase writes and actual system notification UI, without fake delivery.
Changed walkthrough claims are specifications until their current runs pass;
old screenshots are not evidence for this design. Physical sound, routing and
off-wrist results remain a required separate check.
