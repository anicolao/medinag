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
Snooze action starts a native one-minute post-alert countdown. A custom Stop
intent saves a pending response and registers/verifies a new, separately
identified one-minute follow-up alarm before requesting deferred foreground
execution. It does not wait for a rendered screen, network, or patient response
to arm that follow-up. The app shows two equally styled choices:

- **Yes, I did:** cancel all test alarms and verify that the OS inventory is empty.
- **Yes, I will:** register/verify a new one-minute snooze before cancelling the
  previous follow-up, then return to the setup screen.

Every replacement includes the same Stop intent. Stopping another follow-up
without responding therefore repeats this process. Duplicate Stops for a retired
identifier cannot create additional alarms. Stop is never medication completion.
The pending response and identifiers are saved atomically to a phone-local file
and restored on relaunch. These are PoC-local responses, not Firestore writes;
native and in-app snoozes remain one minute, not the production anchored grid.

The public setup screen also has **Stop and respond**, an in-app App Intent
button for practising this flow. Its automated smoke check is not proof that a
system Stop/× or locked-device slider invoked the intent or opened the app.

There is an unavoidable failure window if iOS does not execute the Stop handler
or it crashes before the new OS alarm is registered. A verified follow-up rings
without further app execution, but is not preinstalled before the original Stop.
Deferred foreground is an OS request, not permission to bypass unlocking or
force the patient to remain in the app. Registration failures are logged and
shown; they are not represented as successful follow-up protection.

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
   alarm; then Stop. Confirm MediNag asks for a response. Leave without answering
   (or swipe the app away); confirm another actual alarm occurs one minute after
   Stop. Stop that alarm and choose **Yes, I did**; verify no further alarm.
   Repeat with **Yes, I will** and verify the one-minute snooze alarm. Do not
   confuse notification-list presence with sound. Set a NEW alarm after upgrading
   from build 19: already-registered build-19 alarms do not acquire a Stop intent.
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
single-alarm registration/replacement, process relaunch, cancellation, and the
public in-app Stop intent/both response choices, using event-driven conditions
capped at two seconds. The initial two smoke tests passed. The opt-in native
countdown Stop diagnostic FAILED to find the system Stop control in Simulator;
it is explicitly skipped in the normal smoke suite, not replaced by an in-app
action and called a system-action pass. It can be run with
`TEST_RUNNER_MEDINAG_SYSTEM_STOP_DIAGNOSTIC=1` and
`-only-testing:MediNagAlarmPrototypeUITests/PrototypeUITests/testSystemCountdownStopPresentation`.
The locked/already-ringing Stop/× journey, foregrounding, audible follow-up,
Snooze, and Focus bypass still require the hardware test above. Custom sound is
used in both Simulator and device builds, with no
simulator-only substitution presented as equivalent evidence.

Release with `npm run ios:testflight:alarm-prototype`. The existing signing/ASC
configuration and Internal TestFlight group are reused. Release checks require
the Live Activity extension and sound, and reject an embedded Watch app. The
normal `npm run ios:testflight` still builds the medication executable.
