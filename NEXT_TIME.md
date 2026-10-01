# Next Time

## Current State

PR #6 is merged, completing Phase 1 of the iOS MVP plan. Phase 2 work is on the
fresh `agent/ios-mvp` branch. The detailed plan is recorded in
[IOS_MVP_PLAN.md](IOS_MVP_PLAN.md), and app-specific setup is in
[apps/ios/README.md](apps/ios/README.md).

The phase establishes a shared household data model before an Apple client is
added:

```text
households/{householdId}
├── members/{uid}
├── schedules/{scheduleId}
└── medicationEvents/{eventId}
```

## Account-Linking Recovery

The first production linking attempts successfully attached Lori's and Alex's
Google credentials, but the migration stopped before creating either household.
The application checked whether `households/{uid}` existed before creating it,
while the original rules denied that read until the household existed. All seven
legacy schedules remained intact under their now-Google-linked owner UIDs.

PR #6 now permits a signed-in user to read only their own household path during
bootstrap. The production rule is deployed, and an emulator regression test
covers the exact missing-document read, creation, membership, and migration-
version sequence with server timestamps. The dashboard also falls back to the
legacy schedule path with a retry banner if any future migration step fails,
instead of failing application initialization.

## Completed Before This Phase

- The cross-platform, zero-pixel E2E guide was merged in PR #3.
- The dashboard scaffold and GitHub Pages previews were merged in PR #4.
- Firebase-backed schedule management was merged in PR #5.
- The production Firebase project is `medinag`; Pages receives its web
  configuration through GitHub Actions secrets.

## Phase 1 Scope

- Enable Google Sign-In alongside anonymous Firebase Auth.
- Let Lori link the anonymous dashboard she already used to her Gmail account.
- Preserve her existing schedules by migrating them from the legacy admin path
  to her Google-linked household.
- Handle the case where the Gmail credential already belongs to a Firebase user
  by signing into that account and copying the schedules captured before sign-in.
- Add advisor and subject membership roles with emulator-tested Firestore rules.
- Give subjects read-only schedule access and tightly constrained snooze and
  completion event writes.
- Add the minimal Today dashboard for pending, snoozed, and completed doses.
- Add US-003 with exact screenshots of the link, migration, and Today states.

## Decisions Made

- Lori uses Google for the durable advisor identity.
- A household, rather than an admin UID, owns schedules and medication events.
- Legacy schedule documents remain in place as rollback evidence; the linked
  application switches to household documents.
- Steve's subject account is provisioned with the iOS client in Phase 2.
- Deterministic E2E uses local fixtures and emulators; production smoke tests are
  separate and must not drive visual baselines.

## Phase 2 Scaffold

- Added a generated SwiftUI project under `apps/ios` with provisional bundle ID
  `org.boardgamescafe.medinag`.
- Pinned Xcode 26.2, iOS 26.2, iPhone 17, XcodeGen 2.46.0, and Firebase Apple SDK
  12.17.0.
- Added a portable `MediNagCore` package with injected clock, event store, and
  notification scheduler. Its three deterministic checks pass under the local
  Swift 6.3 compiler.
- Added one-time Steve sign-in, household membership verification, Firestore
  listeners, next-dose and Today states, notification readiness, snooze,
  completion, repeat scheduling, and cancellation.
- Added accessibility identifiers and an XCTest walkthrough scaffold enforcing
  two-second event-driven conditions and exact RGBA screenshot equality.
- Added a macOS 26 GitHub Actions workflow that will build with Xcode 26.2 on a
  pull request.

The local computer still has only Apple Command Line Tools. Swift sources parse
and the portable core compiles, but the SwiftUI/Firebase target and simulator
cannot be run locally until full Xcode and the iOS runtime are installed.

## Next Steps for Phase 2

1. Confirm or replace the provisional permanent bundle identifier before
   registering it with Firebase.
2. Install Xcode 26.2 plus the iOS 26.2 simulator locally, or push the branch so
   the pinned GitHub runner can perform the first complete build.
3. Register the Firebase Apple app and supply `GoogleService-Info.plist` outside
   source control.
4. Enable email/password Auth, create Steve's account, and add its UID as the
   subject member of Lori's household.
5. Generate and review the first iOS zero-pixel walkthrough baselines.
6. Exercise a production schedule/event from the iPhone simulator before moving
   to the Phase 3 cross-surface walkthrough.

## Remaining Questions

- Is `org.boardgamescafe.medinag` the permanent bundle identifier, and which
  Apple development team should sign device builds?
- Is the implemented one-time email/password plus household-ID flow acceptable
  for Steve, or should Phase 2 add a pairing code before production testing?
- When should legacy anonymous schedules be deleted, if ever?
- Is GitHub Pages only the review host, or the intended long-term production
  host?
