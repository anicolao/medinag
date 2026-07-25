# Next Time

## Current State

Work is on `agent/admin-scheduling` in draft
[PR #5: Add admin schedule management](https://github.com/anicolao/medinag/pull/5).
The current implementation commit is `8e73404`.

The live PR dashboard is available at:

<https://anicolao.github.io/medinag/pr5/>

All required GitHub checks pass. The live preview was also exercised directly
with event-driven Playwright assertions: a production-backed schedule was
created, edited, and paused successfully.

## Completed Work

- Merged [PR #3](https://github.com/anicolao/medinag/pull/3), which added the
  cross-platform E2E guide for the web dashboard, iOS app, and watchOS app.
  It requires zero screenshot-pixel tolerance, event-driven synchronization,
  generated user-story walkthroughs, and bounded execution times.
- Merged [PR #4](https://github.com/anicolao/medinag/pull/4), which scaffolded
  the admin dashboard, added its first exact E2E walkthrough, and established
  GitHub Pages production and per-PR preview deployment.
- Added the admin medication-scheduling experience in PR #5:
  - Empty, add, edit, active, paused, and resume states.
  - Recurring weekday selection and time entry.
  - Real-time Firestore subscriptions.
  - Responsive dashboard styling.
  - US-002 documentation with five exact screenshots.
- Pinned the Firebase Web SDK and Firebase CLI in `package.json`.
- Created the real Firebase project `medinag` and registered the
  `MediNag Admin Dashboard` web app using Firebase CLI.
- Created the standard Firestore database in `nam5` and enabled database
  deletion protection.
- Added and deployed Firebase Auth configuration with anonymous sign-in.
- Added and deployed Firestore rules and indexes. Preview schedules live under
  `admins/{firebaseUid}/schedules`, so each anonymous browser session can access
  only its own workspace.
- Stored all eight Firebase web-app configuration fields as GitHub Actions
  secrets. The Pages workflow maps them to `VITE_FIREBASE_*` variables at build
  time; no configuration values were committed to the repository.
- Kept deterministic local E2E isolated from production. Without Firebase
  environment configuration, the dashboard uses browser-local storage. Firebase
  configuration is validated against the local Auth and Firestore emulators.
- Confirmed the production dependency audit is clean. The current Firebase CLI
  dependency tree still has documented development-only transitive advisories.

## Questions to Resolve

1. What is the permanent authentication experience for Lori?
   Anonymous authentication makes the PR preview immediately testable, but a
   real admin account should eventually use email/password, passkeys, Google
   sign-in, or another deliberate provider.
2. Should schedules belong to an admin UID, a subject, or a household?
   The current per-browser UID isolation is safe for previews but will not let
   Lori, Steve's iPhone, and Steve's Watch share the same schedule data. Agree on
   the production ownership and role model before adding the Apple clients.
3. Should reviewers share seeded demo data, or should every preview remain
   private? Private workspaces avoid reviewers interfering with each other;
   shared fixtures may be more useful for cross-device demonstrations.
4. How should anonymous preview accounts and their test data be cleaned up?
   The completed production smoke test left one paused schedule in its isolated
   anonymous workspace. It is not visible to other sessions, but a cleanup or
   expiry policy should be established before previews are widely shared.
5. Should production smoke coverage be automated?
   The production path has been verified manually with Playwright, while the
   committed visual suite intentionally avoids production mutations.
6. Is GitHub Pages the intended long-term production host, or only the review
   environment? This affects authentication domains, routing, and deployment
   ownership.

## Possible Next Steps

1. Review and merge PR #5.
2. Choose the account, household, subject, and role model; migrate the Firestore
   path and rules to that model.
3. Implement Lori's real sign-in and replace anonymous preview authorization
   for the production dashboard.
4. Add Firebase App Check and an explicit preview-data retention policy before
   broader external testing.
5. Scaffold the iOS app, register its Firebase app, and implement schedule
   synchronization plus the first iOS E2E walkthrough.
6. Add the watchOS companion target, WatchConnectivity behavior, and its first
   user-story walkthrough.
7. Build the remaining dashboard areas: Today, nag and escalation rules, and
   compliance history.
8. Add a production smoke workflow with isolated test identity/data and
   deterministic cleanup if production testing should run continuously.
9. Code-split Firebase Auth and Firestore from the welcome route to remove the
   current large-bundle warning.
