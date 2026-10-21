# MediNag iPhone MVP

This directory contains the SwiftUI patient application. The project is generated
reproducibly from `project.yml`; the generated `MediNag.xcodeproj` is committed for
review and direct use.

## Pinned environment

- Xcode 26.6
- iOS 26.5 / iPhone 17 Simulator
- XcodeGen 2.46.0
- Firebase Apple SDK 12.17.0
- Google Sign-In iOS SDK 9.2.0
- iOS 17 deployment target

## Implemented behavior

- Persistent Google/Firebase sign-in; no app-managed password or pairing ID.
- Public discovery by administrator name, plan name, or stable schedule code.
- Explicit one-to-one schedule following and change-schedule confirmation.
- Live Firestore dose and medication-event listeners.
- Automatic recovery when the administrator disconnects the patient.
- Today, next-dose, notification-readiness, pending, snoozed, and completed states.
- iOS 26 AlarmKit reminders that keep sounding through silent mode and Focus,
  remain owned by iOS when MediNag is suspended or terminated, and open the
  response screen by tapping the system-owned alarm.
- A bundled 14.9-second spoken-and-bell sound for the AlarmKit alert. The
  system alarm remains alerting until the patient opens or dismisses it. The
  Simulator uses Apple's default alarm tone because the
  iOS 26 Simulator crashes SpringBoard when loading any external AlarmKit sound;
  every physical-device and TestFlight build uses `MediNagAlarm.caf`.
- Equal-weight `Yes, I did` and `Yes, I will` actions, available only after a
  notification is opened.
- Administrator-configured snooze interval and maximum reminder count, including
  restoration after the app relaunches.
- Completion cancellation and Firestore response writes.
- Firestore offline caching and queued writes.
- An injected clock, event store, and notification scheduler in `MediNagCore`.
- Event-driven native tests and exact RGBA screenshot comparison with zero
  differing pixels.

AlarmKit requires iOS 26. On older supported iOS versions MediNag uses a
time-sensitive, one-shot local-notification fallback, which cannot offer the same
continuous alarm guarantee. Critical Alerts and APNs are not used. AlarmKit
alerts are forwarded to a paired Apple Watch according to the user's system
notification settings. Administrator incident reporting and SMS escalation are
implemented by the Firebase backend.

## Generate and check

From the repository root:

```bash
npm run ios:core:check
npm run ios:generate
```

The generator downloads pinned XcodeGen and verifies its SHA-256 digest. To run
the Xcode tests directly:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project apps/ios/MediNag.xcodeproj \
  -scheme MediNag \
  -configuration E2E \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' \
  -derivedDataPath apps/ios/DerivedData
```

## Production Firebase and Google Sign-In

The bundle identifier is `org.boardgamescafe.medinag`. Place the production
Firebase Apple configuration at
`apps/ios/MediNag/Resources/GoogleService-Info.plist`; the file is ignored by Git.
The Firebase iOS app must use the same bundle ID and Google authentication must be
enabled. The Google token is exchanged for a Firebase credential and persisted by
Firebase Auth; no credential belongs in source or build settings.

An administrator must sign into the website, add at least one active dose, and
publish the schedule. A new patient then signs into the iPhone app, continues
through the visible Firebase preparation state, selects that administrator, and
follows the plan. No administrator-side patient provisioning is required.

## Install on a physical iPhone

The device runner uses automatic signing and an optional owner-only App Store
Connect handoff. With an unlocked login keychain, one paired iPhone in Developer
Mode, and the production Firebase plist in place, run:

```bash
npm run ios:device
```

It validates Firebase identifiers, detects the phone, generates the project,
signs a serial build, installs it, and launches MediNag. Override selection with
`MEDINAG_IOS_DEVICE_ID`; use `MEDINAG_APPLE_CONFIG` for a different signing
handoff.

## Release through TestFlight

MediNag reuses the owner-only App Store Connect handoff already installed for
the Board Games Cafe Apple team. Apple does not permit app-record creation via
its API, so the first release requires one manual App Store Connect record with
name **MediNag**, bundle ID `org.boardgamescafe.medinag`, SKU `medinag-ios`, and
primary language English (Canada). The bundle ID itself is already registered.

After that record exists, one command discovers the next build number, archives
and validates the app with production Firebase configuration, uploads it, waits
for Apple processing, assigns it to the Internal group, and adds the configured
internal tester:

```bash
npm run ios:testflight
```

Private keys and Apple account identifiers remain outside the repository. Use
`MEDINAG_APPLE_CONFIG` to select a different owner-only handoff.

## Interactive connected environment

```bash
npm run e2e:local
```

This starts fresh Firebase Auth and Firestore emulators, generates unique Google
administrator and patient identities, starts the dashboard at
`http://127.0.0.1:5174/#/schedules`, and launches MediNag in a dedicated Simulator.
Add and publish Lori's dose in the browser. On the phone, sign in with Google,
select Lori's published plan, and follow it. The schedule and event arrive through
the real Firestore listener. Nothing in the story is preloaded.

## Automated connected walkthrough

```bash
npm run ios:e2e:connected
```

The test drives the same browser and phone journey, then:

1. requests alarm permission through the app and native system sheet;
2. backgrounds MediNag before the first alarm;
3. opens the 8:00 AM AlarmKit alert and chooses `Yes, I will`;
4. verifies the Firestore snooze and configured 10-minute repeat;
5. backgrounds and terminates the app again;
6. opens reminder 2 at the logical 8:10 AM time and chooses `Yes, I did`;
7. verifies Firestore completion and alarm cancellation.

The affine E2E clock only compresses the dates supplied to the production
AlarmKit scheduler. The test then waits on an actual `mobiletimerd` alarm-alert
request; it never manufactures an alert. It interacts with the real system
aperture and proves that it foregrounds or cold-launches MediNag. Production
alarms are owned by iOS, so they survive suspension or termination and keep
sounding until the system action is used. No test sleeps or fixed polling
delays are used.

The checked-in walkthrough is
`tests/e2e/004-ios-respond-to-dose/README.md`; CI exports XCTest attachments and
requires every retained RGBA pixel to match its baseline. The backgrounding step
captures the interior of MediNag's real SpringBoard icon because the Simulator
wallpaper varies between devices. The walkthrough crops Apple's animated
ringing glyph plus unrelated wallpaper from expanded AlarmKit screenshots. It
retains the real expanded alarm title and close control and never masks,
replaces, or synthesizes system UI.

The runner enables Reduce Transparency using the Simulator's
`EnhancedBackgroundContrastEnabled` preference. The connected native test checks
`UIAccessibility.isReduceMotionEnabled` and
`UIAccessibility.isReduceTransparencyEnabled` before starting the story, so an
ineffective preference write fails explicitly. On the current implementation,
all 14 dose-response screenshots match exactly across three fresh Simulators.
Baselines contain actual captured pixels; the zero-pixel gate remains enabled.

Registration evidence is persisted after AlarmKit accepts each alarm, so an app
restart cannot misreport an already delivered occurrence as never registered.
The saved alarm details also let a system-alarm cold launch present the response
before Firestore reconnects. They are recorded from the real scheduled event;
patient answers continue through the normal Firestore repository.
The response screen opens when the patient returns to an alerting alarm; a
Firestore update alone does not dismiss a foreground system alarm.

Device verification remains required for the custom sound: schedule a dose a
few minutes ahead, allow alarms, terminate MediNag, enable silent mode and Focus,
and let the alarm fire. Confirm the spoken-and-bell sound, tap the system alarm,
choose `Yes, I will`, terminate again, and confirm the configured repeat. Complete
the dose and verify completion on the dashboard. iOS always permits system
dismissal; dismissing an alarm is not a medication completion, and backend
overdue/SMS escalation still applies.
