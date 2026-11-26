# Phone AlarmKit proof of concept

This is a separate, phone-only executable under the existing MediNag TestFlight
identity. It is **not a medication scheduler**. It deliberately has no Firebase,
Watch app, WatchConnectivity, notification-repeat allocator, background refresh,
or synthetic delivery events. The existing medication executable remains in the
repository; the `MediNagAlarmPrototype` scheme does not compile or run it.

## What the tester can do

Choose 1–60 minutes and tap **Set test alarm**. After real AlarmKit authorization,
the app chooses and displays a whole-second deadline, registers a single fixed
AlarmKit alarm with a pre-alert countdown and bundled custom sound, and checks
the actual OS inventory for that identifier and exact date. It does not request
an app wake at the deadline. Setting another test replaces the previous one.
The deadline is rounded up to the next second, never earlier than the selected
delay after authorization completes.

The embedded WidgetKit extension renders the actual AlarmKit Live Activity on
the Lock Screen and Dynamic Island. iOS supplies the Stop control. The secondary
Snooze action starts a native one-minute post-alert countdown; this experiment
does not implement medication responses or anchored snoozes. Stop does not mark
any medication taken. Relaunching reads the real OS inventory and does not
silently reschedule an alarm that was stopped or cancelled.

The first test clears the old MediNag **phone** notification queue and old
MediNag AlarmKit registrations after the user grants alarm authorization. It
does not modify Firestore or clear any Watch's independent old queue. For a
phone-only experiment, remove the old MediNag Watch app or switch the Watch off.
Existing server medication escalation/SMS behavior is unchanged by this binary.

## Authorization and urgency

AlarmKit's system alarms break through Focus and silent mode with the user's
alarm authorization. This is not a UserNotifications Critical Alert and does not
require or claim Apple's special Critical Alerts entitlement. Configuration
includes a real `NSAlarmKitUsageDescription`, `NSSupportsLiveActivities`, and an
embedded Live Activity extension. No invented entitlement, background-audio
mode, notification fallback, or remotely delivered alert is used.

The app cannot force a particular hardware volume, prevent a user withdrawing
permission, make a powered-off phone ring, or make an alarm impossible to stop.
The experiment exists to measure the OS behavior, not certify those guarantees.
AlarmKit can forward system presentation to a paired Watch, but no Watch behavior
is implemented, tested, or promised here.

Apple references:

- [AlarmKit experience and Focus/silent behavior](https://developer.apple.com/videos/play/wwdc2025/230/)
- [AlarmKit configuration and required countdown extension](https://developer.apple.com/documentation/alarmkit/scheduling-an-alarm-with-alarmkit)
- [System-provided Stop control](https://developer.apple.com/documentation/alarmkit/alarmpresentation/alert-swift.struct)

## Manual test procedure

1. Install the new **MediNag PoC** TestFlight build; open it and set a one-minute
   test. Allow Alarms when asked. Confirm the exact requested time and successful
   OS registration, then lock the phone.
2. Record when sound first starts, what is visible, and how loud/persistent it is.
   Try native Snooze and verify the one-minute countdown and subsequent real
   alarm; then Stop. Do not confuse notification-list presence with sound.
3. Repeat separately with Sleep/Do Not Disturb, silent mode, and the app swiped
   away after registration. Keep the phone powered on. Verify the Live Activity
   separately from audible alerting; neither is evidence of the other.
4. Use **Share test report** after returning to the app and add the observed
   first-sound time, settings, and button pressed. Its timestamps distinguish the
   requested deadline and registration from OS state observed while our process
   runs. They do not fabricate an audible-delivery receipt while suspended.

This experiment has no approved visual baselines and is not a dashboard-to-dose
E2E claim. Its actual public input is the user-selected delay, intentionally
requested for this PoC; no fake medication schedule or identity is seeded.

## Build and checks

Minimum iOS is 26.1. Generate the project with `npm run ios:generate` and select
the `MediNagAlarmPrototype` scheme. `PrototypeUITests` exercises real permission,
single-alarm registration/replacement, process relaunch, and cancellation, using
event-driven conditions capped at two seconds. It does not prove audible timing,
Focus bypass, or the system Stop/Snooze journey; those require the hardware test
above. Custom sound is used in both Simulator and device builds, with no
simulator-only substitution presented as equivalent evidence.

Release with `npm run ios:testflight:alarm-prototype`. The existing signing/ASC
configuration and Internal TestFlight group are reused. Release checks require
the Live Activity extension and sound, and reject an embedded Watch app. The
normal `npm run ios:testflight` still builds the medication executable.
