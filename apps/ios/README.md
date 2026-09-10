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
- System-rendered local notifications that cold-launch the response screen.
- Equal-weight `Yes, I did` and `Yes, I will` actions, available only after a
  notification is opened.
- Administrator-configured snooze interval and maximum reminder count, including
  restoration after the app relaunches.
- Completion cancellation and Firestore response writes.
- Firestore offline caching and queued writes.
- An injected clock, event store, and notification scheduler in `MediNagCore`.
- Event-driven native tests and exact RGBA screenshot comparison with zero
  differing pixels.

Critical Alerts, APNs, watchOS, SMS verification, and SMS escalation are deferred.

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
publish the schedule. A new patient then signs into the iPhone app, selects that
administrator, and follows the plan. No administrator-side patient provisioning
is required.

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

1. requests notification permission through the app and native system sheet;
2. backgrounds and terminates MediNag before the first notification;
3. opens the 8:00 AM system notification and chooses `Yes, I will`;
4. verifies the Firestore snooze and configured 10-minute repeat;
5. backgrounds and terminates the app again;
6. opens reminder 2 at the logical 8:10 AM time and chooses `Yes, I did`;
7. verifies Firestore completion and notification cancellation.

E2E notification delivery advances on the app-background event and then waits for
the actual SpringBoard notification. Production uses calendar notifications owned
by iOS, so they survive suspension or termination. No test sleeps or fixed polling
delays are used.

The checked-in walkthrough is
`tests/e2e/004-ios-respond-to-dose/README.md`; CI exports XCTest attachments and
requires every RGBA pixel to match its baseline.
