# Local notifications while Critical Alerts approval is pending

## What this build is, and is not

`MediNagNotificationPatient` is a phone-owned local-notification implementation
using the existing real Firebase/Google sign-in, followed schedule, durable
response outbox and administrator reporting. It has no Watch executable,
AlarmKit scheduling, Live Activity, APNS request, custom Stop intent, or separate
Watch queue. On launch it cancels authorized old AlarmKit registrations owned by
the main MediNag app; it cannot cancel the separate Alarm Lab's alarms.

The visible banner says **Ordinary notification test. Critical Alerts approval
pending. Silent mode and Focus can suppress sound.** Notifications use ordinary
`.active` interruption and the system sound. This is NOT validated medication
protection and does NOT demonstrate Critical Alerts, DND/silent breakthrough,
guaranteed delivery or indefinite repetition.

The app keeps the two equally weighted response buttons. An upcoming dose can
only be completed within 15 minutes; outside that window it shows only the next
dose. Inside the app, responding returns to the next-dose screen (the previously
approved iOS alternative to programmatically closing an app).

## Short manual test

1. In the old **MediNag Alarm Lab**, tap **Finish test**. Then install the new
   **MediNag Notifications** TestFlight build and open it online. Allow
   notifications. For an audible ordinary-notification test, turn off silent
   mode/Focus and allow sounds, with adequate alert volume.
2. Add an explicitly labelled test dose at least five minutes ahead through the
   real administrator dashboard, and open MediNag to synchronize. Use valid
   server settings, for example repeat **3 minutes**, snooze **10 minutes**.
   Lock the phone. Record when the notification actually arrives and sounds.
3. Expand the notification (press and hold) to see **Yes, I did** and
   **Yes, I will**. To test ignored reminders, dismiss it without either action;
   another notification is already registered for the next repeat time. There
   is no need to leave a sound ringing. Native Watch forwarding may route the
   ordinary notification to the Watch instead of the phone; record which device.
4. Choose **Yes, I will**. Follow-ups before the anchored snooze deadline should
   disappear. For an 08:00 dose with a ten-minute snooze, a tap at 08:03 targets
   08:10; a tap at 08:12 targets 08:20. At expiry, test **Yes, I did** and confirm
   completion on the dashboard and no more notifications for that dose.
5. Repeat with the app terminated, a relaunch, and an offline tap followed by
   reconnection. Only mark actual medication taken when it really was; explicit
   test doses can be completed as test records. Remove test doses afterward.

The notification-body tap opens the response screen; custom buttons run in the
background without requesting foreground launch. Ignoring, opening or dismissing
is not recorded as taking or snoozing a dose. A newer dose supersedes the old one;
responding to a stale notification cannot revive a completed/older occurrence or
apply to a rescheduled dose, different account, or old snooze version.

## Scheduling and recovery

- The same pure planner is used for ordinary and future Critical Alerts builds.
  R/S come from the administrator; snooze is on the original dose-time grid.
  Occurrences use the real patient's timezone as materialized by the server.
- Up to **60** one-shot calendar notifications are owned by this executable.
  Reserve complete first-30-minute blocks for the current and next dose first;
  fill spare capacity with complete later windows. An old window is cut off
  strictly before its successor, even if the app never runs at the transition.
- Invalid settings (e.g. two 31-request one-minute windows) have existing web
  configuration warnings. The phone still allocates best effort to both windows,
  records failure, and creates an administrator incident/SMS request; it never
  reports full coverage. It does not deliberately disable all reminders.
- Queue updates happen on real schedule/settings snapshots, responses, foreground
  launch/relaunch, and best-effort background refresh. We request an opportunity
  after 15 minutes, but iOS does not promise one. Offline continuation only covers
  the actual preloaded requests. Reopen the app periodically; this finite queue
  is not a guarantee of perpetual protection.
- Response persistence precedes cancellation and rebuilding. A crash/restart
  replays the durable response state, not a new user tap. Server synchronization
  starts as soon as possible and retries on connectivity/foreground opportunities.
  It never delays local action completion waiting for Firestore.
- A just-due pending request is not canceled merely because its deadline passed
  before iOS consumed it. Keep at most the newest eligible in-flight request.
  Complete/snooze/retirement still removes it. The final SDK readback checks
  request IDs, absolute dates, urgency and the budget.

## Evidence and test boundaries

OSLog category `LocalNotifications` and real Firestore `deviceEvents` distinguish
add acceptance, pending-inventory verification, actual notification observations,
action callbacks, durable responses, cancellation and server acknowledgements.
Action logs include seconds since the requested alert; response logs also include
seconds since the original dose. A foreground callback or a system notification
date is not an audible-delivery receipt. No general background audible-delivery
callback exists here; missing evidence stays unknown, not a fabricated success.

Failures are durably recorded, then create administrator incidents through the
existing SMS pipeline. SMS is a server responsibility; offline failure reports
cannot reach it until connectivity returns. SMS provider acceptance is not proof
of SMS delivery. A pending/denied notification setup is never reported ready
based on old AlarmKit inventory.

`npm run ios:core:check` covers example-date timing/capacity/retirement/snooze
rules as UNIT tests. The connected `MediNagNotificationPatient` story uses real
Auth/Firestore/Functions emulators, dashboard-created schedules, real notification
authorization/SDK registration/readback, early in-app completion, relaunch and
return-to-dashboard verification. It explicitly does not validate timed system
presentation, notification action buttons, background termination delivery,
offline recovery, or Critical Alerts sound. Those remain physical manual tests;
the tests do not inject callbacks or manufacture notification delivery.

Current native screenshots are functional evidence, not approved zero-pixel
visual baselines. No new visual-regression or full alert-walkthrough pass is
claimed. The signed TestFlight archive is also checked for no Watch/extension/
custom sound and for absence of the Critical Alerts entitlement in this trial.

## Once Apple approves

`MediNagCriticalPatient` compiles the same planner, engine and action handlers.
It requests `.criticalAlert`, requires the permission to remain enabled, and
schedules `.critical` notifications with full-volume default critical sound.
Its signing entitlement is in `LocalNotifications/Critical.entitlements`.
This target cannot be distributed without an approved provisioning profile;
adding the plist alone is not approval. The release script verifies the actual
signed entitlement before upload. Rebuild profiles and physically test on-time
locked-screen delivery, silent/Focus breakthrough, both actions, ignored repeats,
Watch routing, offline responses and relaunch recovery before claiming success.

Release the ordinary build:

```sh
MEDINAG_TESTFLIGHT_GROUP='Alex Phone Trial' npm run ios:testflight:notifications
```

After approval, use `npm run ios:testflight:critical` with the same group setting.
Critical mode has no ordinary-notification fallback masquerading as success:
missing critical permission is a visible/reportable failure.
