# Single-alarm presentation-path experiment

This is a diagnostic, not validated medication protection. The phone must
actually sound and present the alarm on time; SDK `alerting`, a server receipt,
or a screenshot of the response screen is not a delivery pass.

## Question and matched builds

Does providing the matching Live Activity widget make an alert-only AlarmKit
alarm present reliably on this iPhone? Missing packaging is a hypothesis, not
a confirmed defect: Apple's documented widget requirement concerns countdowns,
and our widget-free baseline sounded at 9:37 AM on November 27.

- **A:** `MediNagAlarmReliability`; no extension or Live Activities declaration.
- **B:** `MediNagAlarmPresentation`; same app sources and compilation conditions,
  plus `MediNagAlarmPrototypeLiveActivity` and `NSSupportsLiveActivities = true`.

Both use real Google/Firebase schedule data, `AlarmAttributes<PrototypeMetadata>`
with nil metadata, exactly one fixed-time alarm, default system sound and
ordinary Stop. No countdown, Snooze, custom actions, Watch executable, custom
audio, queued backup alarms or notification fallback. The diagnostic banner and
`inventory_verified` evidence identify A/B; TestFlight identifies build numbers.
Configuration version 5 forces existing version-4 registrations to be replaced
when either experiment build first reconciles. Both variants use version 5.

`ruby apps/ios/scripts/check-presentation-pair.rb` checks the source/configuration
contract. The release script checks the signed archive's actual packaging.
The existing connected test runs against both schemes and real Firebase
emulators, checking registration/response flows, not physical delivery.

## Short physical procedure

1. Install A from TestFlight's **Previous Builds**. Keep the same iOS version,
   Focus, sound volume, Watch state and other Live Activities for both runs.
   Do not reboot or stop Stopwatch between A and B. End any separate Alarm Lab
   run first. Do not depend on MediNag for medication during this experiment.
2. Use the real administrator web dashboard to enter a test dose at least five
   minutes ahead, distinct from other dose times. Open the phone app online so
   it imports the change. Check the A/B banner and preserve server
   `inventory_verified` evidence: exactly one OS alarm at the intended time.
   A missed earlier dose may still own the sole alarm; acknowledge it or remove
   the obsolete test dose and reopen the app before starting the next run.
3. Set a native Clock control alarm two minutes later. Lock the phone before
   the MediNag deadline. Record its actual sound/UI time, whether either is
   absent, and whether it appears only when Clock rings or the phone wakes.
   A late alarm fails even if the SDK reports `alerting` on time.
4. If it rings, tap ordinary Stop. Stop does not record a medication response
   or guarantee app execution. Open MediNag, record **Yes, I did** for the test
   dose, then use the dashboard to enter a second test dose five minutes ahead.
   Reopen/synchronize MediNag and lock it again to test the post-Stop path.
   Only one alarm is registered at any time; this is not an automatic retry.
5. Capture logs promptly, then install B and repeat steps 2–4 with new dose
   times. If A fails, preserve its logs before using the in-app response to
   clear the missed test dose. Never count a missed real medication as taken.

Capture after a run, with the phone USB-connected:

```sh
sudo /usr/bin/log collect --device-name 'Alex Nicolaou’s iPhone' --last 30m --output /tmp/medinag-presentation-A.logarchive
```

Use `presentation-B` in the output name for B. Record: build/variant, requested
deadline, actual first sound and visible alert times, Stop time, phone locked
state, Focus, Stopwatch/other Live Activities, charging and Clock control result.
Export before rebooting. Compare requested deadline, daemon firing, widget
rendering, ClockAngel scene creation and tone posting by alarm/activity ID.
`Sound Played: nil` alone is not a failure receipt.

If B succeeds, repeat with longer idle time and the original Stopwatch/Focus
conditions before claiming a fix. Change only one environmental condition at a
time. No sequence of simulator registration passes proves audible reliability.

## Failure exit: Critical Alerts

If the widget-present B still misses its deadline, stop the AlarmKit experiment
and proceed directly to requesting Apple's Critical Alerts entitlement for
`org.boardgamescafe.medinag` (team `ZHQLA4T47N`). Do not build another retry
mechanism around this presentation path first.

Request `com.apple.developer.usernotifications.critical-alerts` through Apple's
entitlement request form. Explain the medication-adherence use case, observed
silent/delayed alarms, and need for local audible alerts through silent/Focus.
Apple approval and the patient's separate critical-alert authorization are
required, including for TestFlight. Approval is not guaranteed. The developer
account holder may need to complete the form; prepare supporting evidence rather
than inventing application/contact information or claiming clinical validation.

After approval: update signing/profiles, use phone-owned local critical
notifications with the two response actions and anchored snooze, and physically
validate locked-screen, silent, Focus and Watch-routing behavior. This alternative
still has finite notification-queue capacity and user-controlled authorization;
do not promise guaranteed sound or two-device simultaneous delivery. A Time
Sensitive fallback does not override silent mode and is not equivalent.

References: [AlarmKit sample](https://developer.apple.com/documentation/alarmkit/scheduling-an-alarm-with-alarmkit),
[Critical Alerts entitlement and request form](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.usernotifications.critical-alerts).

## Release

```sh
MEDINAG_TESTFLIGHT_GROUP='Alex Phone Trial' npm run ios:testflight:alarm-reliability
MEDINAG_TESTFLIGHT_GROUP='Alex Phone Trial' npm run ios:testflight:alarm-presentation
```

Run sequentially so each gets a distinct build number. Both replace the same
app without changing server medication data. Ordinary Stop does not guarantee
the next scheduled dose is armed: open the app after each trial. Existing server
overdue/coverage SMS policies remain active; this experiment does not silently
disable them. Remove temporary test doses through the dashboard when finished.
