# MediNag iOS MVP

This directory contains the Phase 2 SwiftUI application for Steve. The project
is generated reproducibly from `project.yml`; the generated `MediNag.xcodeproj`
is committed so it can be reviewed and opened directly.

## Pinned environment

- Xcode 26.6
- iOS 26.5 simulator runtime
- iPhone 17 simulator
- Light appearance, increased contrast, and medium content size
- XcodeGen 2.46.0
- Firebase Apple SDK 12.17.0 through Swift Package Manager
- Application deployment target: iOS 17

Firebase 12.17.0 requires Xcode 26.2 or newer. The pull-request workflow uses
Xcode 26.6 with the iOS 26.5 runtime from GitHub's macOS 26 image for verification.

## What is implemented

- One-time Steve email/password login with persistent Firebase Auth.
- Temporary household-ID pairing, guarded by subject membership rules.
- Read-only schedule and medication-event listeners.
- Today, next-dose, notification-readiness, snoozed, and completed states.
- System-rendered local notifications which cold-launch the response screen.
- Equal-weight `Yes, I will` and `Yes, I did` responses shown only after the
  user taps a notification.
- Ten-minute repeat scheduling, completion cancellation, and Firestore updates.
- Firestore's local persistence and queued writes for offline reconciliation.
- Injected clock, event store, and notification scheduler in `MediNagCore`.
- A currently hard-coded 10-minute snooze default in
  `DoseCoordinator.defaultSnoozeInterval`; the coordinator accepts an injected
  interval so a future schedule setting can replace the default.
- Accessibility identifiers and an event-driven UI walkthrough with no
  real-time snooze wait.
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

After installing Xcode 26.6 and the iOS 26.5 runtime:

```bash
sudo xcode-select --switch /Applications/Xcode_26.6.app
xcodebuild test \
  -project apps/ios/MediNag.xcodeproj \
  -scheme MediNag \
  -configuration E2E \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' \
  -derivedDataPath apps/ios/DerivedData
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

## Run the connected system locally

Run:

```bash
npm run e2e:local
```

This starts isolated Firebase Auth and Firestore emulators, creates fresh Lori
and Steve identities through Auth, establishes their household through
security-rule-checked Firestore writes, starts the dashboard at
`http://127.0.0.1:5174/#/schedules`, and builds the iOS app into a dedicated
Simulator. The terminal prints Steve's generated credentials and household ID.
Sign in with them, then add a schedule in the dashboard. The new schedule and
medication event appear in the app through its live Firestore snapshot listener.

The script opens the dashboard and Simulator automatically. It leaves the
environment running until Control-C so schedules can be edited interactively.
No schedule, event, authenticated state, or response is preloaded by this
workflow.

To execute the same connected story automatically, including system-rendered
notifications and Firestore snooze/completion writes, run:

```bash
npm run ios:e2e:connected
```

That runner creates a disposable Simulator, fixes its status bar at 8:00 AM,
and follows this path:

1. Tap the app's `Allow` button, then tap the system-rendered `Allow` button.
2. Press Home. iOS presents the first notification for 8:00 AM.
3. Tap that notification. It opens MediNag's response screen.
4. Tap `Yes, I will`. The dashboard confirms the 10-minute snooze.
5. Press Home. iOS presents reminder 2 for 8:10 AM.
6. Tap reminder 2, then tap `Yes, I did` to complete the dose.

The E2E configuration publishes each armed notification when MediNag leaves the
screen, so the proof takes seconds while retaining the logical 8:00 and 8:10
times. The production configuration uses calendar-based local notifications;
those requests are owned by iOS and survive the app being suspended or
terminated. The automated walkthrough explicitly terminates MediNag before it
captures and taps either notification.
