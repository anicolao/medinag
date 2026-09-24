# Test: Lori schedules and Steve responds to a dose

> As Lori and Steve, we want a dashboard schedule to become an iOS notification and Steve’s response to return to the dashboard.

## Surface coverage

- **Web Admin Dashboard:** covered
- **iOS:** covered
- **watchOS:** not-applicable — watchOS is deferred until after the iOS MVP.

## Evidence environments

- **connected-emulators:** Fresh Firebase Authentication, Firestore, and Functions emulators running production rules and function code.
- **ios-simulator:** Pinned iPhone 17 / iOS 26.5 Simulator using the production notification scheduler and a scaled timeline.
- **springboard:** The iOS Simulator SpringBoard with MediNag terminated before notification delivery.

## Deterministic preconditions

- Backend: fresh Firebase Authentication, Firestore, and Functions emulators with production rules and function code
- Data: Lori creates the schedule through the dashboard; no schedule or medication event is preloaded or encoded in the native test
- Identity: run-specific Google-provider identities use the Firebase Auth Emulator; this walkthrough does not claim to exercise Google's OAuth consent UI
- Relationship: the patient discovers and follows the administrator's published plan through the iPhone UI; no relationship document is preloaded
- Clock: an affine E2E timeline compresses elapsed time before the production scheduler creates its calendar triggers; it never creates or delivers a notification
- Device: iPhone 17 on iOS 26.5, portrait, light appearance, increased contrast, reduced motion and transparency, medium Dynamic Type
- Status bar: fixed at 8:00 AM with a Simulator override
- System UI: notification permission and both reminders are rendered by iOS SpringBoard
- Lifecycle: the UI test terminates MediNag before it captures or taps either notification
- Snooze interval: 10 minutes from the administrator profile written through the dashboard

## Lori opens a fresh dashboard connected to Firebase

![Lori opens a fresh dashboard connected to Firebase](./screenshots/web/000-empty-connected-dashboard.png)

**Verifications:**

- [x] The dashboard is connected to the isolated Firebase environment
- [x] No dose or medication event has been preloaded

## Lori saves and publishes the medication schedule through the dashboard

![Lori saves and publishes the medication schedule through the dashboard](./screenshots/web/001-schedule-written-to-firestore.png)

**Verifications:**

- [x] The saved medication label is rendered from the Firestore snapshot
- [x] The dashboard confirms the production repository write
- [x] The plan is explicitly published before the iPhone can discover it

## Steve signs into MediNag with Google

![Steve signs into MediNag with Google](./screenshots/ios/000-patient-sign-in.png)

**Verifications:**

- [x] Google is the only sign-in action
- [x] No household identifier is requested

## MediNag signs into the isolated Firebase Auth Emulator identity

![MediNag signs into the isolated Firebase Auth Emulator identity](./screenshots/ios/001-authentication-in-progress.png)

**Verifications:**

- [x] A visible progress state appears before the two-second condition limit
- [x] The user controls when to continue to schedule selection

## Steve finds Lori's published schedule

![Steve finds Lori's published schedule](./screenshots/ios/002-choose-schedule.png)

**Verifications:**

- [x] The schedule chooser is visible
- [x] Lori is discoverable by name
- [x] The published dose summary identifies the plan

## The iPhone follows Lori's schedule and receives its Firestore event

![The iPhone follows Lori's schedule and receives its Firestore event](./screenshots/ios/003-firestore-event-received.png)

**Verifications:**

- [x] The medication label written by Lori appears from the snapshot listener
- [x] The real medication event is pending
- [x] The app offers notification permission

## iOS asks Steve to allow MediNag notifications

![iOS asks Steve to allow MediNag notifications](./screenshots/ios/004-notification-permission.png)

**Verifications:**

- [x] The permission prompt is rendered by iOS
- [x] The system offers an Allow action

## MediNag is ready and waits for the scheduled notification

![MediNag is ready and waits for the scheduled notification](./screenshots/ios/005-waiting-for-first-reminder.png)

**Verifications:**

- [x] Permission and real pending iOS requests are both confirmed
- [x] The Firestore event remains visible while the app waits
- [x] No response is available before a notification
- [x] No completion is available before a notification

## With MediNag terminated, iOS retains the scheduled notification

![With MediNag terminated, iOS retains the scheduled notification](./screenshots/ios/006-first-system-notification.png)

**Verifications:**

- [x] The first reminder is rendered by SpringBoard
- [x] The SpringBoard notification has finished arriving

## Tapping the notification cold-launches the response screen

![Tapping the notification cold-launches the response screen](./screenshots/ios/007-first-reminder-response.png)

**Verifications:**

- [x] The response screen is visible
- [x] The reminder sequence is correct
- [x] The first reminder uses the medication occurrence time
- [x] Yes, I will is available
- [x] Yes, I did is available
- [x] Neither response has greater visual weight

## Yes, I will writes the snoozed response back to Firestore

![Yes, I will writes the snoozed response back to Firestore](./screenshots/ios/008-dose-snoozed-in-firestore.png)

**Verifications:**

- [x] The snooze count increments
- [x] The configured repeat interval is confirmed
- [x] The Firestore listener receives the snoozed state
- [x] The response screen is dismissed

## With MediNag terminated, iOS retains the repeat notification

![With MediNag terminated, iOS retains the repeat notification](./screenshots/ios/009-repeat-system-notification.png)

**Verifications:**

- [x] The repeat is rendered by SpringBoard
- [x] The repeat notification has finished arriving

## Tapping reminder 2 cold-launches the app after logical time advances

![Tapping reminder 2 cold-launches the app after logical time advances](./screenshots/ios/010-repeat-reminder-response.png)

**Verifications:**

- [x] The response screen is visible
- [x] The reminder sequence is correct
- [x] The repeat displays the response-relative snooze expiry
- [x] Yes, I will is available
- [x] Yes, I did is available
- [x] Neither response has greater visual weight

## Yes, I did completes the real event and cancels further reminders

![Yes, I did completes the real event and cancels further reminders](./screenshots/ios/011-dose-completed-in-firestore.png)

**Verifications:**

- [x] The Firestore listener receives completion
- [x] The app confirms notification cancellation

## Lori sees Steve's completion and healthy iPhone coverage

![Lori sees Steve's completion and healthy iPhone coverage](./screenshots/web/002-completion-returned-to-dashboard.png)

**Verifications:**

- [x] The dashboard Firestore listener receives the completed occurrence
- [x] The administrator sees matching pending-request coverage from iOS
- [x] No reminder-system incident remains open
- [x] The healthy path issues no administrator SMS request
