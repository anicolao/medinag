# Test: Lori schedules and Steve responds to a dose

> As Lori and Steve, we want a dashboard schedule to become an iOS notification and Steve’s response to return to the dashboard.

## Surface coverage

- **Web Admin Dashboard:** covered
- **iOS:** covered
- **watchOS:** not-applicable — watchOS is deferred until after the iOS MVP.

## Deterministic preconditions

- Backend: a fresh Firebase Authentication and Firestore emulator suite with security rules enabled
- Data: Lori creates the schedule through the dashboard; no schedule or medication event is preloaded or encoded in the native test
- Identity: unique Google administrator and patient identities are generated for the run through Firebase Auth; no UID, credential, or token is fixed in test source
- Relationship: the patient discovers and follows the administrator's published plan through the iPhone UI; no relationship document is preloaded
- Clock: notification delivery is advanced on the app-background event; logical reminder times remain derived from the Firestore event
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

## The schedule materializes the pending event Steve will receive

![The schedule materializes the pending event Steve will receive](./screenshots/web/002-event-observed-on-dashboard.png)

**Verifications:**

- [x] The pending event arrives through the dashboard Firestore listener
- [x] The event is waiting for Steve’s response

## Steve signs into MediNag with Google

![Steve signs into MediNag with Google](./screenshots/ios/000-patient-sign-in.png)

**Verifications:**

- [x] Google is the only sign-in action
- [x] No household identifier is requested

## Steve finds Lori's published schedule

![Steve finds Lori's published schedule](./screenshots/ios/001-choose-schedule.png)

**Verifications:**

- [x] The schedule chooser is visible
- [x] Lori is discoverable by name
- [x] The published dose summary identifies the plan

## The iPhone follows Lori's schedule and receives its Firestore event

![The iPhone follows Lori's schedule and receives its Firestore event](./screenshots/ios/002-firestore-event-received.png)

**Verifications:**

- [x] The medication label written by Lori appears from the snapshot listener
- [x] The real medication event is pending
- [x] The app offers notification permission

## iOS asks Steve to allow MediNag notifications

![iOS asks Steve to allow MediNag notifications](./screenshots/ios/003-notification-permission.png)

**Verifications:**

- [x] The permission prompt is rendered by iOS
- [x] The system offers an Allow action

## MediNag is ready and waits for the scheduled notification

![MediNag is ready and waits for the scheduled notification](./screenshots/ios/004-waiting-for-first-reminder.png)

**Verifications:**

- [x] Notification permission is ready
- [x] The Firestore event remains visible while the app waits
- [x] No response is available before a notification
- [x] No completion is available before a notification

## With MediNag terminated, iOS retains the scheduled notification

![With MediNag terminated, iOS retains the scheduled notification](./screenshots/ios/005-first-system-notification.png)

**Verifications:**

- [x] The first reminder is rendered by SpringBoard

## Tapping the notification cold-launches the response screen

![Tapping the notification cold-launches the response screen](./screenshots/ios/006-first-reminder-response.png)

**Verifications:**

- [x] The response screen is visible
- [x] The reminder sequence is correct
- [x] The reminder uses the logical scheduled time
- [x] Yes, I will is available
- [x] Yes, I did is available
- [x] Neither response has greater visual weight

## Yes, I will writes the snoozed response back to Firestore

![Yes, I will writes the snoozed response back to Firestore](./screenshots/ios/007-dose-snoozed-in-firestore.png)

**Verifications:**

- [x] The snooze count increments
- [x] The configured repeat interval is confirmed
- [x] The Firestore listener receives the snoozed state
- [x] The response screen is dismissed

## With MediNag terminated, iOS retains the repeat notification

![With MediNag terminated, iOS retains the repeat notification](./screenshots/ios/008-repeat-system-notification.png)

**Verifications:**

- [x] The repeat is rendered by SpringBoard

## Tapping reminder 2 cold-launches the app after logical time advances

![Tapping reminder 2 cold-launches the app after logical time advances](./screenshots/ios/009-repeat-reminder-response.png)

**Verifications:**

- [x] The response screen is visible
- [x] The reminder sequence is correct
- [x] The reminder uses the logical scheduled time
- [x] Yes, I will is available
- [x] Yes, I did is available
- [x] Neither response has greater visual weight

## Yes, I did completes the real event and cancels further reminders

![Yes, I did completes the real event and cancels further reminders](./screenshots/ios/010-dose-completed-in-firestore.png)

**Verifications:**

- [x] The Firestore listener receives completion
- [x] The app confirms notification cancellation