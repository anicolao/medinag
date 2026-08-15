# MediNag iOS MVP

This directory contains the Phase 2 SwiftUI application for Steve. The project
is generated reproducibly from `project.yml`; the generated `MediNag.xcodeproj`
is committed so it can be reviewed and opened directly.

## Pinned environment

- Xcode 26.2
- iOS 26.2 simulator runtime
- iPhone 17 simulator
- XcodeGen 2.46.0
- Firebase Apple SDK 12.17.0 through Swift Package Manager
- Application deployment target: iOS 17

Firebase 12.17.0 requires Xcode 26.2 or newer. The local machine currently has
only Apple Command Line Tools, so it can compile and exercise `MediNagCore` but
cannot build the SwiftUI target or run a simulator. The pull-request workflow
uses GitHub's pinned macOS 26 image for that verification.

## What is implemented

- One-time Steve email/password login with persistent Firebase Auth.
- Temporary household-ID pairing, guarded by subject membership rules.
- Read-only schedule and medication-event listeners.
- Today, next-dose, notification-readiness, snoozed, and completed states.
- Local notification actions `Yes, I will` and `Yes, I did`.
- Ten-minute repeat scheduling, completion cancellation, and Firestore updates.
- Firestore's local persistence and queued writes for offline reconciliation.
- Injected clock, event store, and notification scheduler in `MediNagCore`.
- A currently hard-coded 10-minute snooze default in
  `DoseCoordinator.defaultSnoozeInterval`; the coordinator accepts an injected
  interval so a future schedule setting can replace the default.
- Accessibility identifiers and a two-second, event-driven UI walkthrough.
- Exact native RGBA screenshot comparison with zero differing pixels.

Critical Alerts, APNs, watchOS, polished pairing, and escalation remain deferred
as described in `IOS_MVP_PLAN.md`.

## Generate and check

From the repository root:

```bash
npm run ios:core:check
npm run ios:generate
```

The generation script downloads the pinned XcodeGen release and verifies its
SHA-256 digest before use.

After installing Xcode 26.2 and the iOS 26.2 runtime:

```bash
sudo xcode-select --switch /Applications/Xcode_26.2.app
xcodebuild test \
  -project apps/ios/MediNag.xcodeproj \
  -scheme MediNag \
  -configuration E2E \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2' \
  -derivedDataPath apps/ios/DerivedData \
  CODE_SIGNING_ALLOWED=NO
```

## Firebase setup

The provisional bundle identifier is `org.boardgamescafe.medinag`. Confirm it
before registering the production Firebase app because Firebase does not permit
changing an Apple app's bundle ID after registration.

Once confirmed:

1. Register an Apple app in Firebase project `medinag` with that bundle ID.
2. Download its `GoogleService-Info.plist` into
   `apps/ios/MediNag/Resources/GoogleService-Info.plist`.
3. Enable Firebase email/password authentication.
4. Create Steve's subject account and add
   `households/{loriUid}/members/{steveUid}` with role `subject`.
5. Enter Steve's email, password, and Lori's household UID once in the app.

The real plist is ignored by Git. Credentials are entered by Steve and persisted
by Firebase Auth; they are never committed or placed in build settings.

## Record the first walkthrough

The UI test targets `tests/e2e/004-ios-respond-to-dose`. After the pinned local
simulator is installed, run once with `MEDINAG_RECORD_SCREENSHOTS=1` and
`MEDINAG_E2E_ROOT` set to the repository root to create the native baselines and
README. Subsequent runs omit the recording flag and require exact pixel equality.
