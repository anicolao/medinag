# MediNag

MediNag is a medication reminder system with a web dashboard for the person who
publishes a schedule and an iPhone app for the person who follows it.

The current product model is deliberately simple:

- anyone can sign into the dashboard with Google and publish one schedule;
- anyone can sign into the iPhone app with Google and follow one published
  schedule;
- one administrator schedule has at most one patient follower;
- reminder responses synchronize through Firestore in real time.

The approved journey and visual design are in [UX_DESIGN.md](UX_DESIGN.md).
Cross-platform test requirements are in [E2E_GUIDE.md](E2E_GUIDE.md).

## Repository layout

```text
apps/ios/     SwiftUI iPhone MVP, notification integration, and native tests
tests/e2e/    Reviewable user-story walkthroughs and exact screenshots
ux/mockups/   Approved UX mockup boards
web/          Vite/TypeScript administrator dashboard
```

watchOS and SMS escalation are planned but not yet implemented.

## Web dashboard

```bash
npm install
npm run dev
```

Open `http://127.0.0.1:5174`. The dashboard requires Firebase configuration and
Google Sign-In; it does not fall back to fake browser data.

The administrator can add, edit, pause, and resume recurring doses; configure
the snooze interval, reminder limit, escalation deadline, time zone, name, plan
name, and SMS destination; publish the plan; share its stable code/link; and
disconnect its patient follower.

## iPhone app

The iPhone app uses Google Sign-In, discovers published schedules, claims the
selected schedule's patient slot, subscribes to its doses and events, and writes
snooze/completion responses back to Firestore. The administrator's snooze and
maximum-reminder defaults drive local notification scheduling. See
[apps/ios/README.md](apps/ios/README.md) for generation, Simulator, physical-device,
and signing instructions.

```bash
npm run ios:core:check
npm run ios:generate
```

## Firebase

Firebase CLI `15.24.0` and the Firebase Web SDK are pinned in `package.json`.
The configured production project is `medinag`. Auth and Firestore emulators are
used for normal E2E testing.

```bash
npm run firebase:emulators
nix develop -c npm run firebase:validate
```

The GitHub Pages workflow receives the production web-app configuration through
the `VITE_FIREBASE_*` Actions secrets. Google is the only application sign-in
provider. Legacy schedule documents are read only during administrator sign-in
so existing doses can be copied into the new `administrators/{uid}/doses`
schema; all new reads and writes use the administrator/patient model.

## Real connected E2E testing

For an interactive isolated environment spanning the dashboard and iPhone app:

```bash
npm run e2e:local
```

This starts fresh Auth and Firestore emulators, opens Lori's localhost dashboard,
and launches the iPhone app. Add a dose and publish the plan in the browser, then
sign into the phone, choose Lori's schedule, and follow it. The real Firestore
snapshot listener delivers the dose and medication event to the app.

For automated coverage:

```bash
npm run test:e2e:connected
npm run ios:e2e:connected
```

The full story creates both Google identities through the Auth emulator, enters
and publishes the schedule through the visible web UI, discovers and follows it
through the visible iPhone UI, uses system-rendered notifications, and returns
the patient responses to Firestore. It uses event-driven waits only, enforces a
two-second condition timeout, and compares screenshots with zero-pixel tolerance.

Hardcoded schedules, events, identities, relationships, fake repositories, and
browser-storage seed data are forbidden in E2E tests.
