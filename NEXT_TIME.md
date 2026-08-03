# Next Time

## Current State

PR #5 is merged. Phase 1 of the iOS MVP plan is in draft
[PR #6](https://github.com/anicolao/medinag/pull/6) on
`agent/link-lori-google-account`. The detailed plan is recorded in
[IOS_MVP_PLAN.md](IOS_MVP_PLAN.md).

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

## Next Steps After Phase 1

1. Install and pin full Xcode and an iOS Simulator runtime. This machine
   currently exposes only Apple's Command Line Tools.
2. Choose the permanent iOS bundle identifier.
3. Register the iOS Firebase app and provide its configuration outside source
   control.
4. Build the execution-only SwiftUI client with schedule sync, notification
   readiness, snooze, and completion behavior.
5. Add the cross-surface web/iOS closed-loop walkthrough described in
   `IOS_MVP_PLAN.md`.

## Remaining Questions

- What bundle identifier and Apple development team should be used?
- Should Steve initially sign in with provisioned credentials or a pairing code?
- When should legacy anonymous schedules be deleted, if ever?
- Is GitHub Pages only the review host, or the intended long-term production
  host?
