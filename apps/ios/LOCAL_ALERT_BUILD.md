# Local-alert test build

This is an implementation/test-build checkpoint for the requirements reviewed
in PR #8, not a claim that every journey or notification-delivery guarantee is
validated.

## Implemented

- Two equal response choices for a due alert on phone and Watch, without patient
  diagnostics, connection messages, saving screens, or response-confirmation UI.
- A minimal next-dose view, with only Yes, I did at/within 15 minutes.
- Original-dose snooze grid: 8:03 -> 8:10 and 8:12 -> 8:20 for S = 10 minutes.
- Administrator-wide R/S, received by the native clients; existing profiles
  without the new repeat setting retain the previous three-minute default.
- Real local notifications with background actions, not APNs or foreground actions.
- Durable local responses, immediate local-state changes, retry on actual network
  restoration/activation, and original-tap timestamps for delayed synchronization.
- Cached startup, response replay, completed-latest retirement, and local queue
  reconciliation that applies offline responses before installing reminders.
- On-device JSON-lines scheduling, OS-observation and response evidence in
  Library/Application Support/LocalAlerts/local-alerts.jsonl. A previous segment
  is retained after rotation. Neither registration nor queue disappearance is
  logged as proof that a person saw/heard an alert.

## Approved test-build exception

On 2026-11-11 the user approved returning to the minimal next-dose screen after
an in-app response for this TestFlight build. A notification action is configured
to complete without opening the app. This does not establish a supported API for
automatically closing a foreground iPhone application or waive the final UX goal.

## Evidence and remaining work

- Native unit/integration checks cover anchored snoozes, configurable cadence,
  exact early-completion boundaries, real durable-file reload, retirement and
  real OS notification-category configuration. These are not delivery E2E proof.
- The connected functional diagnostic is separate from approved visual testing.
  It uses real UI-created schedules, Firebase emulators/rules, real OS local
  notifications and production responses. The in-app response journey must not
  be described as tapping the notification's custom action.
- The accelerated grouped-notification action walkthrough has failed to open an
  individual actionable OS card reliably. It remains a failing/unverified path,
  not a passing test or permission to manufacture a notification.
- Existing visual baselines are not updated. A strict local visual run failed;
  diagnostic screenshots are not approved zero-pixel evidence.
- Physical phone/Watch routing, sound/haptics and background notification actions
  still require device evidence. There is no universal background delivery receipt.
- The current OS-owned queue remains bounded to 60 requests. With R = 3 minutes,
  a densely filled queue covers roughly three hours, not seven days of repeats.
  It cannot promise indefinite unattended repeats, guaranteed background renewal,
  or that every future initial alert beyond that queue is already registered.
  Do not describe this build as fixing that architectural coverage limit.
- Server-enforced uniqueness of scheduled times is not implemented by this client
  checkpoint. Legacy duplicate schedules must not be represented as an approved
  simultaneous-medication UX.

## Short manual check after installing

1. Open the new build once with a connection so it can refresh its real schedule
   and save the local cache. Allow notifications if the OS asks.
2. Schedule an upcoming alert through the administrator dashboard. Background the
   app and observe the actual phone/Watch alert; record expected and actual times.
3. Ignore once, then choose Yes, I will. Check expiry against the original dose's
   snooze grid, not ten minutes after the tap. Answer Yes, I did on either device.
4. Check that both devices stop that episode and that answering the latest dose
   never brings back an earlier missed one. Separately test early completion.

This short procedure does not replace the automated suite, endurance testing,
or an approved walkthrough. Keep independent reminders while validating this
development build's still-unproven unattended coverage.
