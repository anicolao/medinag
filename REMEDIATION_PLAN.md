# MediNag E2E Remediation Plan

## Goal

Remove every test-only behavior that can make a walkthrough appear to prove
something the production application does not do. After this remediation, an E2E
claim must correspond to behavior we expect from the TestFlight build under the
same stated preconditions.

The connected walkthrough must prove this contract:

> An administrator publishes a medication schedule. The production backend
> materializes its upcoming dose occurrences. A signed-in patient follows that
> schedule in the patient's local time zone, receives those occurrences through
> Firestore, and the iOS production notification scheduler registers a rolling
> seven-day window with iOS. After MediNag is terminated, iOS displays the
> reminder. Opening it presents the correct occurrence, and the patient's
> responses travel back through Firestore to the administrator. The app requests
> daily background refresh to extend the window. A failure anywhere in this
> safety path becomes an administrator incident and triggers a deduplicated SMS
> alert.

A controllable clock may compress elapsed time, but it must drive the same
timeline calculation, notification scheduler, Apple trigger type, application
lifecycle, and persistence path used by Release builds.

## Current Findings to Remediate

The present evidence must not be treated as proof of production notification
behavior:

- The E2E build bypasses the production `UNCalendarNotificationTrigger`, stores a
  reminder in an in-process test store, and later creates a separate 1.5-second
  `UNTimeIntervalNotificationTrigger`.
- A hidden tap gesture on the notification-readiness label manually causes each
  notification. Backgrounding the application does not advance the clock as the
  walkthrough claims.
- The simulator status bar is changed without changing application or system
  time.
- The E2E Google path injects an emulator token and therefore does not test the
  Google OAuth UI, despite copy that describes it as real Google authentication.
- Production has active doses but no medication-event documents. Migrated doses
  do not create events, and no recurring event materializer exists.
- The iOS client can only schedule an event after it has run and received that
  event. It cannot learn of a new Firestore event while suspended or terminated.
- Past events are silently ignored while the UI can still say that reminders are
  ready.
- Client-visible and backend failures do not currently create an administrator
  incident or send an SMS alert.
- TestFlight build 1 predates the latest branch changes.
- No connected iOS GitHub Actions run for the current work has passed. The
  checked-in walkthrough must therefore be labelled unverified and replaced.

## Non-Negotiable Truthfulness Rules

### Production-path parity

- E2E must build the application with the Release implementation of notification
  scheduling. A test may inject time and Firebase endpoints, but not a scheduler,
  notification-delivery store, notification payload, response router, or trigger
  type.
- Remove the E2E-only notification store, accelerated-delivery method, hidden
  notification gesture, acknowledgement counter, and all UI-test calls that
  manually cause a notification.
- No application transition may be triggered through an invisible control,
  accessibility-only mutation, direct view-model call, or private URL intended
  only for tests.
- An accelerated test must use the same Apple notification API and trigger type
  as production. Seeing a real SpringBoard banner is necessary but not sufficient;
  the request that produced it must originate from the production scheduler.
- The test must terminate MediNag before delivery, not after observing delivery.
- E2E state must enter through visible user actions or the same externally
  reachable Firebase interface used in production.

### Honest claims

- Every walkthrough statement must name exactly what was observed. For example,
  an Auth Emulator sign-in may be called "Firebase Auth Emulator sign-in," not
  "real Google sign-in."
- "Reminders are ready" may only appear when authorization is granted and at
  least one expected notification request is confirmed as pending with iOS.
- A screenshot is presentation evidence, not data-flow evidence. Each screenshot
  step must be backed by assertions for the corresponding Firestore, scheduler,
  lifecycle, or system-UI condition.
- A failed, cancelled, skipped, retried, or incomplete run may not generate or
  publish an approved walkthrough.
- Preview, component, unit, emulator-connected, production smoke, and manual tests
  must be named distinctly. None may be presented as another category.

### Allowed test substitutions

The following substitutions are allowed when they preserve production semantics:

- Firebase Auth, Firestore, and Functions emulators in place of the hosted
  services.
- Fresh, run-specific users and story input.
- A scaled clock that maps logical medication time onto a short real interval.
- A captured, wire-compatible SMS provider endpoint, provided the walkthrough
  calls it a captured request rather than delivered SMS.
- Pinned locale, time zone, appearance, simulator, OS version, and accessibility
  settings.
- Disabled animations and deterministic status-bar presentation.

The clock is the only allowed substitute in the notification-delivery path. It
must be injected at the timeline boundary, before the production scheduler builds
the notification request. It must not manufacture or deliver a notification.

## Recommended Production Architecture

### 1. Materialize dose occurrences on the backend

Add Firebase Functions and use the Functions emulator in connected tests.

- A Firestore trigger reconciles future medication events whenever an active dose
  is created, edited, resumed, paused, or deleted.
- A scheduled production function extends a rolling event horizon each day.
- Use deterministic occurrence identifiers derived from administrator, dose,
  the patient's local calendar date, and the patient's current IANA time zone.
  Repeated invocation must be idempotent.
- Start with a seven-day horizon. Six daily doses produce 42 first-reminder
  requests, leaving room below iOS's pending-notification limit for snoozes and
  other application notifications.
- Treat schedule times as patient-local wall-clock times: 8:00 AM means 8:00 AM
  where the patient is taking the medication, never 8:00 AM in the
  administrator's time zone.
- Store the patient's current IANA time zone on the patient/device synchronization
  record and store both that zone and the resolved UTC instant on every
  occurrence. Define daylight-saving gaps and repeated-hour behavior before
  implementation.
- Do not materialize actionable occurrences until a patient follows the schedule
  and supplies a valid time zone. Before that, the dashboard may preview the
  schedule only as "patient local time."
- When the patient's device reports a changed time zone, reconcile future
  occurrences and replace the corresponding pending iOS requests. Preserve
  completed history at its original resolved instant.
- Reconciliation cancels or supersedes future pending events after schedule
  edits, pauses, deletions, publication changes, or patient relationship changes.
- Completed historical events remain immutable except for an explicit retention
  policy.

The E2E story must create the dose through the dashboard and wait for the
Firestore-triggered function to create the event. The test may not call a private
materialization helper or write an event directly.

### 2. Make local notification scheduling observable and reconcilable

Retain local iOS notifications for the initial reliable MVP, but make their
contract explicit:

- On sign-in, follow, foreground, and event snapshot changes, reconcile the
  earliest actionable events against `UNUserNotificationCenter` pending requests.
- Use stable identifiers containing the occurrence ID and reminder number.
- Remove obsolete requests and replace changed requests.
- Bound the scheduling horizon and report how many upcoming reminders iOS has
  accepted.
- Treat an Apple scheduling error or a missing expected pending request as a
  visible not-ready state.
- Distinguish notification permission from notification scheduling. Permission
  alone must never imply that a dose reminder is registered.
- Define explicit states for future, due, missed, snoozed, completed, cancelled,
  and expired occurrences. Do not silently discard a past occurrence.
- Add a user-visible diagnostics view showing authorization status, last
  successful Firestore sync, patient time zone, scheduled-through date, and the
  next registered reminder. It must use real production state and be useful on
  TestFlight; it must not be a test backdoor.

Once a local notification request is accepted, iOS owns its delivery and it
should survive application suspension or termination. This guarantee applies
only to events the phone has already synchronized.

### 3. Refresh the seven-day window daily

Use sync-ahead local notifications for the MVP. Remote APNs refresh is not
required for this phase.

- Register an iOS `BGAppRefreshTask` and request another refresh after every
  successful or failed run, with an earliest begin date approximately one day in
  the future.
- Add the required background-task identifier, Background Fetch capability, task
  registration at launch, expiration handling, and completion reporting to the
  Release target; these must not exist only in the test configuration.
- Each refresh reports the patient's current time zone, reads the rolling
  seven-day event horizon, reconciles pending iOS notification requests, and
  writes a device coverage record containing `lastRefreshAt`, `timeZone`,
  `scheduledThrough`, application build, and reconciliation result.
- Also run the same refresh coordinator at sign-in, follow, application launch,
  and foreground entry. Background and foreground refreshes must share the same
  production implementation.
- Keep seven complete patient-local calendar days scheduled. A daily refresh
  normally consumes one day and adds the newly materialized seventh day.
- The backend's daily materializer and the phone's daily refresh are independent
  and idempotent. Either may retry without duplicating events or notification
  requests.
- If the patient's time zone changed, refresh reconciles all future events before
  registering the new requests.

iOS background refresh is opportunistic: the app may request a daily wake, but
iOS decides whether and when it runs. Force-quitting the app can also prevent
background execution until the patient opens it again. The seven-day buffer is
therefore a resilience window, not proof of a guaranteed daily wake.

To make this robust without pretending iOS offers a guarantee:

- show the patient and administrator the synchronized-through date;
- have the backend monitor device coverage independently;
- create an incident before coverage falls below an approved safety margin, such
  as 48 hours; and
- send the administrator an SMS if the device stops refreshing, reports a failed
  reconciliation, or no longer has the expected pending reminders.

The deterministic CI suite can prove the production refresh coordinator and
seven-day reconciliation. It must not claim that CI proved iOS chose to wake the
app overnight. A physical-device soak test and production coverage telemetry
provide that evidence.

### 4. Log failures and alert the administrator

A patient-visible failure is also an administrator incident. Telling only the
patient is not an acceptable failure mode.

- Add a `systemIncidents` collection with deterministic incident keys, severity,
  source, administrator, patient/device, error code, first/last occurrence,
  status, retry state, and sanitized diagnostic context.
- Log notification authorization loss, local scheduling rejection, pending-request
  mismatch, Firestore synchronization failure, expired background work, stale
  schedule coverage, time-zone reconciliation failure, backend materialization
  failure, and SMS delivery failure.
- Client failures are written to Firestore and displayed locally. A Firebase
  Function observes new or materially changed incidents, records them on the
  administrator dashboard, and sends an SMS to the administrator's configured
  SMS number.
- If the client cannot reach Firestore, persist the incident in an encrypted local
  outbox and submit it on the next connection. The backend coverage monitor must
  independently detect the missing heartbeat so a completely offline client can
  still cause an administrator SMS.
- Deduplicate repeated failures, apply an alert cooldown, and update the existing
  incident rather than creating an SMS storm. Escalate again only when severity
  increases or the approved reminder interval expires.
- Record SMS provider message ID, acceptance or rejection, attempts, and final
  status. Never report an SMS as sent merely because an HTTP request was made.
- Show open and resolved incidents in the administrator dashboard. Resolution
  requires observed recovery, such as restored coverage and matching pending
  requests, rather than a patient dismissing an error.
- The emulator E2E uses a captured, wire-compatible SMS gateway and may claim
  only that the production function issued and recorded the expected provider
  request. A production smoke test must prove that the configured provider
  delivers a real SMS to the administrator.

## Honest Clock Acceleration

Replace the alternate E2E scheduler with one injected timeline implementation.

- Define a clock/timeline interface that supplies logical `now` and converts a
  logical deadline into the real delay used by the production notification
  scheduler.
- Production uses a one-to-one system timeline.
- Connected E2E uses an affine scaled timeline: for example, ten logical minutes
  can elapse in less than one real second.
- The production scheduler constructs the same notification content, identifier,
  and Apple trigger in both configurations.
- The accelerated clock begins from a run-specific logical instant. Expected
  labels such as 8:00 and 8:10 must be derived from Firestore data, not separately
  hardcoded into the native test.
- Advancing time must be event-driven. Once the schedule exists and the app has
  registered its notification, the test backgrounds and terminates the app and
  waits for SpringBoard. It performs no hidden tap or direct trigger call.
- Keep the two-second maximum for each automated condition. If the scheduler
  cannot deliver within that bound using the scaled timeline, the test fails.

Before implementation, prototype and document the exact Apple trigger strategy.
If the chosen production trigger cannot be driven by the scaled timeline without
substitution, change the production scheduling design rather than adding another
test-only delivery path.

## Test Suite Reconstruction

### Phase 0 — Quarantine invalid evidence

- Mark the existing iOS notification walkthrough as unverified.
- Prevent PR #7 from being merged while its connected iOS check is absent,
  cancelled, or failing.
- Do not delete the old screenshots initially; move or label them as historical
  diagnostic artifacts so the replacement can be reviewed side by side.
- Record the source commit, build configuration, Xcode version, simulator runtime,
  and Firebase target in every future walkthrough manifest.

### Phase 1 — Backend occurrence tests

Using Auth, Firestore, and Functions emulators, prove:

- creating an active dose produces the expected future occurrences;
- migrated active doses receive occurrences during idempotent backfill;
- repeated reconciliation produces no duplicates;
- edits move future occurrences without changing history;
- pause, resume, delete, unpublish, and relationship changes reconcile correctly;
- daily horizon extension creates only missing occurrences;
- each occurrence uses the linked patient's reported IANA time zone rather than
  the administrator's time zone;
- patient travel and daylight-saving boundaries reconcile future occurrences
  according to the approved policy;
- stale device coverage and materialization failures create deduplicated
  administrator incidents;
- incident creation invokes the SMS provider adapter and records the captured
  provider result;
- an undeliverable SMS remains a visible, retryable incident rather than being
  reported as sent;
- security rules permit only the intended administrator, patient, and backend
  operations.

These are integration tests of deployed function handlers and Firestore rules,
not in-process repository substitutes.

### Phase 2 — Production scheduler integration tests

Test the real `LocalNotificationScheduler` against
`UNUserNotificationCenter` on Simulator:

- authorization state is reported accurately;
- future events become pending requests with the expected identifiers, payloads,
  trigger dates, sounds, categories, and interruption levels;
- changed and cancelled events remove or replace requests;
- missed events follow the approved missed-dose behavior;
- a snooze schedules exactly one configured repeat;
- completion cancels all remaining requests for that occurrence;
- pending-request reconciliation is idempotent;
- application relaunch reconstructs the same state from Firestore and iOS;
- foreground and background entry points call the same production refresh
  coordinator;
- a refresh extends device coverage back to seven patient-local calendar days;
- a patient time-zone change replaces future requests at the newly resolved
  instants;
- refresh expiration, Firestore failure, and pending-request mismatch write a
  durable incident or local outbox entry.

Recording/mock notification implementations remain acceptable for narrow unit
tests, but their results must be labelled unit coverage and never cited as Apple
delivery evidence.

### Phase 3 — Rebuild the connected walkthrough

The replacement story must perform these observable steps:

1. Start fresh Auth, Firestore, and Functions emulators with production rules and
   function code.
2. Create a unique administrator through the dashboard authentication flow.
3. Add, configure, and publish a dose through visible dashboard controls.
4. Observe the backend-generated occurrence on the dashboard.
5. Start the iOS application with emulator Firebase endpoints and the scaled
   timeline, using the Release notification implementation.
6. Sign in through the explicitly labelled Auth Emulator flow.
7. Report the patient's device time zone, then discover and follow the
   administrator through visible iOS controls.
8. Request notification permission through the native iOS sheet.
9. Assert that the expected occurrence is present in Firestore and the expected
   production notification request is pending with iOS at the patient's local
   medication time.
10. Background and terminate MediNag without invoking any test delivery action.
11. Observe and capture the first SpringBoard notification.
12. Tap it and verify the cold-launched response screen is derived from the same
    occurrence.
13. Choose **Yes, I will** and verify the Firestore snooze plus the production
    pending repeat request.
14. Terminate MediNag again and observe the scaled ten-minute repeat through
    SpringBoard.
15. Choose **Yes, I did** and verify Firestore completion, dashboard completion,
    and absence of remaining requests for the occurrence.

All waits remain event-driven and individually limited to two seconds. The test
must fail if any expected event, request, system notification, response, or
cross-client update is absent.

### Phase 4 — Prove failure reporting and SMS escalation

Add a separate connected failure story using a production-supported, observable
failure condition rather than a test-only thrown error. For example, revoke
notification permission through iOS Settings after a reminder was registered.
The story must prove:

1. the patient sees the real not-ready state;
2. the client writes or queues a structured incident;
3. the administrator dashboard receives the same open incident;
4. the production Firebase Function sends one request to the captured SMS
   gateway;
5. the provider result is recorded and duplicate snapshots do not send duplicate
   SMS messages; and
6. restoring permission and pending coverage resolves the incident through
   observed recovery.

Add backend-only failure cases for conditions a client cannot report, including a
stale device heartbeat, expiring scheduled coverage, materializer failure, and
SMS provider rejection. Their walkthrough copy must distinguish a captured SMS
provider request from real SMS delivery.

### Phase 5 — Authentication coverage

Separate two claims that are currently conflated:

- The normal connected E2E uses a run-specific Auth Emulator identity and says so
  in its walkthrough.
- A separate real-device smoke test validates the actual Google consent/sign-in
  flow against production Firebase.

The emulator token may not be described as proof of the Google OAuth UI. The
TestFlight smoke test may reuse an already approved tester account, but it must
record which authentication state was exercised.

### Phase 6 — Release-equivalent and TestFlight validation

- Build connected E2E with the Release application implementation plus only
  endpoint and clock injection at the composition root.
- Add a build-time/static audit that rejects E2E-only schedulers, notification
  stores, payload builders, trigger builders, hidden mutation gestures, and test
  actions in application UI code.
- Embed the Git commit SHA and build configuration in application diagnostics and
  in the walkthrough manifest.
- Archive only a commit whose required CI checks have passed.
- Upload a new TestFlight build after remediation; do not reuse build 1 as
  evidence.
- Run a controlled production smoke story on a physical iPhone using a dose a few
  real minutes in the future. This is intentionally a production smoke test, not
  the two-second deterministic CI E2E.
- Send and receive a real administrator SMS from a controlled production incident
  and record the provider delivery status.
- Run a physical-device background-refresh soak long enough to observe at least
  one system-granted refresh extending the scheduled-through date. This is the
  evidence for iOS wake behavior; deterministic CI must not claim it.
- Capture the dashboard state, TestFlight build/SHA, notification settings,
  registered next reminder, lock-screen notification, response screen, and final
  dashboard result.

No production smoke screenshot becomes a deterministic pixel baseline. It is a
release artifact proving that hosted Firebase, real Google authentication,
TestFlight signing, and physical-device notification delivery work together.

## CI and Walkthrough Safeguards

- The connected iOS job must be a required PR check. Cancelled and skipped are not
  acceptable conclusions.
- The screenshot exporter runs only after the complete XCTest passes.
- Walkthrough generation validates that every declared step has a fresh
  screenshot and assertion manifest from the same run.
- Baseline comparison runs only on complete artifacts. Recording mode must also
  require a passing test.
- Baseline updates are committed separately from application changes when
  practical and include a link to the passing recording run.
- Preserve zero-pixel comparison after functional validity is established. Pixel
  equality must never compensate for an invalid data or notification path.
- Add a source audit that fails on prohibited patterns such as test-only
  notification delivery, hidden mutable gestures, direct event seeding, or E2E
  prose claiming production services that were not used.
- Add a claims manifest mapping each walkthrough statement to its verifying
  assertion and environment. Documentation generation must use that manifest
  rather than hand-written success claims.
- Retain failure artifacts, including the XCTest result bundle, application and
  SpringBoard screenshots, pending-request diagnostics, emulator logs, and
  Firestore/Functions logs.
- Retain incident documents and captured SMS provider exchanges for failure
  stories, with secrets and personal data redacted.
- Fail CI if an alertable client or backend failure does not produce an
  administrator incident, or if repeated processing produces duplicate SMS
  requests.

## Production Data Repair

After the new materializer and rules pass emulator tests:

1. Export or otherwise back up the affected Firestore collections.
2. Confirm that each administrator has a validated SMS destination; do not
   silently enable schedules whose failures have nowhere to escalate.
3. Deploy functions, indexes, incident handling, SMS integration, and rules
   together.
4. Have each linked phone report its current IANA time zone before backfill.
5. Run an idempotent backfill for every published administrator's active doses,
   resolving occurrences in the linked patient's time zone.
6. Verify that Lori's and Alex's active doses have the expected upcoming events.
7. Open each linked TestFlight phone, synchronize, and verify the diagnostics view
   reports the correct patient time zone, scheduled-through date, and next
   registered reminder.
8. Perform the controlled physical-device notification, background-refresh, and
   real-SMS smoke stories.
9. Retain an audit report of documents created, changed, skipped, and rejected.

No production backfill occurs until its dry-run output has been reviewed.

## Acceptance Criteria

Remediation is complete only when all of the following are true:

- No E2E-only notification scheduler, delivery store, trigger builder, hidden
  gesture, or manual notification action exists in application code.
- The connected test uses the same Apple trigger implementation as Release.
- Clock acceleration changes elapsed time only; it does not create or deliver
  notifications.
- Active schedules continuously produce deterministic upcoming events without an
  administrator reopening or editing them each day.
- Occurrences and displayed medication times are resolved in the patient's
  current time zone, including after a reported time-zone change.
- Migrated doses receive events through the same idempotent materialization
  policy.
- The app visibly distinguishes permission from successfully registered
  reminders.
- The app requests daily background refresh, uses the same refresh coordinator in
  foreground and background, and maintains a seven-day scheduled window whenever
  iOS grants execution.
- Patient and administrator UIs show the last refresh and scheduled-through date;
  neither claims a guaranteed future background wake.
- Every alertable client or backend failure creates a durable administrator
  incident. Client offline failures are covered by a local outbox plus independent
  backend heartbeat monitoring.
- Each new or materially escalated incident produces one deduplicated SMS attempt
  to the administrator, with provider acceptance, delivery, rejection, and retry
  state recorded accurately.
- The connected dashboard-to-iPhone-to-dashboard story passes in CI with every
  condition at or below two seconds and no sleep, retry, polling loop, or hidden
  test control.
- The walkthrough and screenshots are generated from that successful run and
  contain no claims beyond its assertions.
- A new TestFlight build identifies the same passing commit.
- A physical-device production smoke test proves real Google authentication,
  hosted Firestore data, local iOS delivery while MediNag is terminated, snooze,
  completion, dashboard reflection, and real administrator SMS delivery.
- A physical-device soak records at least one iOS-granted background refresh that
  extends the seven-day window. CI makes no stronger claim about OS wake timing.
- The documented product contract states that new schedule changes are picked up
  on foreground or the next iOS-granted background refresh; APNs refresh is not
  part of this MVP.

## Decisions for Review

The following decisions are now recorded:

- the MVP uses seven-day sync-ahead local notifications;
- the app requests daily background refresh and also refreshes on foreground;
- APNs refresh is deferred;
- medication wall-clock time belongs to the patient and uses the patient's
  reported IANA time zone; and
- alertable failures are logged, shown to the administrator, and escalated by
  SMS.

Before implementation, confirm the remaining policy details:

1. The desired missed-dose behavior when the phone first synchronizes after the
   scheduled time.
2. Whether a time-zone change immediately moves all future reminders or asks the
   patient to confirm travel first.
3. The low-coverage and stale-heartbeat thresholds; the plan currently proposes
   an administrator alert before fewer than 48 scheduled hours remain.
4. Which failures are warning versus critical severity and the SMS repeat/cooldown
   policy for each.
5. The SMS provider and whether recovery should send a second "resolved" SMS or
   update only the dashboard.
6. Whether every TestFlight candidate requires physical-device notification,
   background-refresh, and real-SMS smoke tests, or whether those gates apply only
   to affected releases.

Until these decisions and acceptance criteria are satisfied, the project may
claim that connected clients exchange data through Firebase, but it must not
claim that production medication notifications have been proven.
