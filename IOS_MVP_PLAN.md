# iOS MVP Plan

## Recommendation

Build the iOS MVP as one continuous initiative, but split delivery into three
reviewable pull requests. A single large pull request is technically possible,
but the current per-browser Firebase ownership cannot support iOS. The shared
data and authentication foundation should be validated before notification code
depends on it.

## MVP Success Criterion

The MVP proves this closed loop:

1. Lori signs into the web dashboard and creates a schedule.
2. Steve's iOS app receives it from Firestore.
3. An injected clock triggers the dose without real-time waiting.
4. Steve chooses "Yes, I will" or "Yes, I did."
5. The iOS app updates Firestore.
6. Lori sees the updated status in the dashboard.
7. A separate smoke test repeats the flow against production Firebase.

## Prerequisites

- Finish and merge draft
  [PR #5](https://github.com/anicolao/medinag/pull/5), then branch from updated
  `main`.
- Install and pin full Xcode plus an iOS Simulator runtime. The current machine
  has only Command Line Tools; `xcodebuild` and `simctl` are unavailable.
- Choose the permanent iOS bundle identifier.
- Preserve the unrelated untracked `resume` file currently in the workspace.

## Phase 1: Shared Firebase Contract and Web Status

Replace the preview-only ownership model with a real shared household:

```text
households/{householdId}
├── members/{uid}              role: advisor | subject
├── schedules/{scheduleId}
└── medicationEvents/{eventId}
```

For Phase 1, link Lori's existing anonymous Firebase account to Google. Normal
linking preserves her UID; if that Gmail address already has a Firebase account,
the migration copies her captured schedules into that account's household.
Steve's subject account will be provisioned with the iOS client in Phase 2.

### Deliverables

- Lori login and existing-data linking through Google.
- Household membership and role-based Firestore rules.
- Lori can manage schedules; Steve can only read them.
- Steve can update only permitted medication-event fields.
- Minimal Today dashboard showing pending, snoozed, and completed doses.
- Emulator rule tests and deterministic fixture accounts.

### Exit Criterion

A fixture acting as Steve updates a dose event and Lori's dashboard observes it
in real time.

## Phase 2: iOS MVP

Create a SwiftUI app under `apps/ios` with:

- Firebase Auth and Firestore through Swift Package Manager.
- Firebase iOS configuration supplied outside source control.
- One-time Steve login with persistent authentication.
- Execution-only next-dose and today-status screens.
- Notification permission and readiness UI.
- A local notification category with "Yes, I will" and "Yes, I did."
- Snooze, repeat-nag, completion, and cancellation behavior.
- Firestore synchronization and offline write reconciliation.
- An injected clock and scheduler for tests.
- Accessibility identifiers and the Swift `TestStepHelper`.

### Exit Criterion

The pinned simulator builds and tests successfully, receives a schedule, and
records both response types without fixed waits.

## Phase 3: Closed-Loop Walkthrough

Add a cross-surface E2E story that orchestrates Playwright, XCTest, and Firebase
emulators:

1. Lori creates a schedule on the web.
2. Steve sees the next dose on iOS.
3. The test advances the injected clock.
4. Steve snoozes once.
5. The next nag is emitted.
6. Steve confirms completion.
7. Lori sees the completed status.

The suite will enforce:

- Maximum two-second condition timeouts.
- Event-driven synchronization only.
- Zero-pixel screenshot tolerance.
- Pinned Xcode, runtime, simulator, locale, timezone, and status bar.
- Generated web and iOS walkthrough documentation.
- A separate production-Firebase smoke test, since deterministic visual CI must
  not mutate production.

## Explicitly Deferred

This iOS MVP proves the core closed loop, but does not yet include:

- watchOS.
- Twilio escalation.
- Cloud Scheduler or automated escalation.
- Apple Critical Alerts entitlement.
- Remote APNs pushes.
- Full compliance history and export.
- Polished device-pairing UX.

If the goal is to prove the literal entire product scheme, including Apple Watch
and SMS escalation, that should be a second initiative after this vertical
slice.

## Decisions Needed for Approval

The recommended defaults are:

- Three sequential pull requests.
- Lori's Google account and one shared household, followed by Steve's subject
  account in Phase 2.
- Local iOS notifications for the MVP.
- Simulator-driven deterministic E2E plus one production smoke flow.
- Watch, Twilio, APNs, and Critical Alerts deferred.

The remaining inputs are the preferred bundle identifier and confirmation that
full Xcode can be installed.
