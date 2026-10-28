# Independent phone and Watch reminders

The current manual-testing candidate is **0.1.0 (14)**, including the matching
signed Watch app. Builds 11–13 were intermediate uploads; use 14. Local checks:
15 native unit tests and eight portable core checks passed; both native targets
compiled. The updated connected walkthroughs and physical dual-device delivery
are not approved evidence. The first updated iPhone run reached real system
delivery but failed its notification accessibility locator. The latest paired
run failed initial Watch dose synchronization within the strict two-second
condition. No timeouts were extended or failed captures promoted to baselines.

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

The phone owns authentication and transactional writes. The Watch owns a separate
notification queue from its last real synchronized snapshot. Watch responses use
interactive WatchConnectivity plus a persisted background transfer. A duplicate
or stale response cannot increment snooze twice. Neither device claims success
until the server transaction is acknowledged. A disconnected Watch response
remains pending and its reminders remain active until confirmation arrives.
Transient phone startup/reconnection snapshots cannot erase a ready Watch cache
or its queued alerts. Only a confirmed unlink/sign-out can clear it; a native
regression test verifies this distinction and older cached-payload decoding.

The Watch shows only the medication and next reminder time. At strictly less
than 15 minutes before that time, or when overdue, it also shows the two equally
weighted responses. Completed history, administrator headings, readiness panels,
refresh controls, and scrolling have been removed. Necessary connection/failure
messages remain.

## Important limits — not production guarantees

- Each device registers at most 60 pending alerts. Upcoming initial doses get
  priority, then spare slots hold the earliest three-minute follow-ups. This is
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

Automated tests use the same planner and UserNotifications APIs. Native unit
tests verify planning, strict response-window boundaries, response-version
protection and actual registered action categories. Connected walkthroughs must
verify Firebase writes and actual system notification UI, without fake delivery.
Changed walkthrough claims are specifications until their current runs pass;
old screenshots are not evidence for this design. Physical sound, routing and
off-wrist results remain a required separate check.
