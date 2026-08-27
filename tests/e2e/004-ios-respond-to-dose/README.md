# Test: Lori schedules and Steve responds to a dose

> As Lori and Steve, we want a dashboard schedule to become an iOS notification and Steve’s response to return to the dashboard.

## Surface coverage

- **Web Admin Dashboard:** covered
- **iOS:** covered
- **watchOS:** not-applicable — watchOS is deferred until after the iOS MVP.

## Deterministic preconditions

- Backend: a fresh Firebase Authentication and Firestore emulator suite with security rules enabled
- Data: Lori creates the schedule through the dashboard; no schedule or medication event is preloaded or encoded in the native test
- Identity: advisor and subject credentials are generated for the run through Firebase Auth
- Clock: notification delivery is advanced on the app-background event; logical reminder times remain derived from the Firestore event
- Device: iPhone 17 on iOS 26.5, portrait, light appearance, increased contrast, medium Dynamic Type
- Status bar: fixed at 8:00 AM with a Simulator override
- System UI: notification permission and both reminders are rendered by iOS SpringBoard
- Lifecycle: the UI test terminates MediNag before it captures or taps either notification
- Snooze interval: 10 minutes from `DoseCoordinator.defaultSnoozeInterval`

## Lori opens a fresh dashboard connected to Firebase

![Lori opens a fresh dashboard connected to Firebase](./screenshots/web/000-empty-connected-dashboard.png)

**Verifications:**

- [x] The dashboard is connected to the isolated Firebase environment
- [x] No medication schedule has been preloaded

## Lori saves the medication schedule through the dashboard

![Lori saves the medication schedule through the dashboard](./screenshots/web/001-schedule-written-to-firestore.png)

**Verifications:**

- [x] The saved medication label is rendered from the Firestore snapshot
- [x] The dashboard confirms the production repository write

## The schedule materializes the pending event Steve will receive

![The schedule materializes the pending event Steve will receive](./screenshots/web/002-event-observed-on-dashboard.png)

**Verifications:**

- [x] The pending event arrives through the dashboard Firestore listener
- [x] The event is waiting for Steve’s response

## Steve signs in to the same Firebase household

![Steve signs in to the same Firebase household](./screenshots/ios/000-subject-sign-in.png)

**Verifications:**

- [x] The real Firebase Auth form is visible
- [x] The password field is visible
- [x] The household pairing field is visible

## The iPhone receives Lori's schedule and event through Firestore

![The iPhone receives Lori's schedule and event through Firestore](./screenshots/ios/001-firestore-event-received.png)

**Verifications:**

- [x] The medication label written by Lori appears from the snapshot listener
- [x] The real medication event is pending
- [x] The app offers notification permission

## iOS asks Steve to allow MediNag notifications

![iOS asks Steve to allow MediNag notifications](./screenshots/ios/002-notification-permission.png)

**Verifications:**

- [x] The permission prompt is rendered by iOS
- [x] The system offers an Allow action

## MediNag is ready and waits for the scheduled notification

![MediNag is ready and waits for the scheduled notification](./screenshots/ios/003-waiting-for-first-reminder.png)

**Verifications:**

- [x] Notification permission is ready
- [x] The Firestore event remains visible while the app waits
- [x] No response is available before a notification
- [x] No completion is available before a notification

## With MediNag terminated, iOS retains the scheduled notification

![With MediNag terminated, iOS retains the scheduled notification](./screenshots/ios/004-first-system-notification.png)

**Verifications:**

- [x] The first reminder is rendered by SpringBoard

## Tapping the notification cold-launches the response screen

![Tapping the notification cold-launches the response screen](./screenshots/ios/005-first-reminder-response.png)

**Verifications:**

- [x] The response screen is visible
- [x] The reminder sequence is correct
- [x] The reminder uses the logical scheduled time
- [x] Yes, I will is available
- [x] Yes, I did is available
- [x] Neither response has greater visual weight

## Yes, I will writes the snoozed response back to Firestore

![Yes, I will writes the snoozed response back to Firestore](./screenshots/ios/006-dose-snoozed-in-firestore.png)

**Verifications:**

- [x] The snooze count increments
- [x] The configured repeat interval is confirmed
- [x] The Firestore listener receives the snoozed state
- [x] The response screen is dismissed

## With MediNag terminated, iOS retains the repeat notification

![With MediNag terminated, iOS retains the repeat notification](./screenshots/ios/007-repeat-system-notification.png)

**Verifications:**

- [x] The repeat is rendered by SpringBoard

## Tapping reminder 2 cold-launches the app after logical time advances

![Tapping reminder 2 cold-launches the app after logical time advances](./screenshots/ios/008-repeat-reminder-response.png)

**Verifications:**

- [x] The response screen is visible
- [x] The reminder sequence is correct
- [x] The reminder uses the logical scheduled time
- [x] Yes, I will is available
- [x] Yes, I did is available
- [x] Neither response has greater visual weight

## Yes, I did completes the real event and cancels further reminders

![Yes, I did completes the real event and cancels further reminders](./screenshots/ios/009-dose-completed-in-firestore.png)

**Verifications:**

- [x] The Firestore listener receives completion
- [x] The app confirms notification cancellation
