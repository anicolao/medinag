# Local-alert test build

2026-11-12: TestFlight candidate **18** adds background-launch response handlers,
durable protection against answered-alert resurrection, and retention of valid
OS-owned due requests across refresh. See [the incident report](INCIDENT_2026-11-12.md)
for evidence and limitations. The final system-action walkthrough is **not green**;
a prior phone run passed, but later runs failed to expose grouped notification
buttons. Cold Watch notification actions still require hardware verification.

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

2026-11-11 checkpoint: 32 native tests, 8 core checks, 14 Firestore rule tests,
9 backend checks, TypeScript checking and the truthfulness audit passed. The
three-part connected in-app diagnostic passed (web creation, native real OS
notification/in-app responses, web completion). The repeat-setting rules were
deployed to medinag. These results do not make the full existing CI/visual suite
or the separate grouped-notification custom-action story green.

Subsequent 30-minute-window revision: 38 native tests, 8 core checks, 4 capacity
warning checks, 10 backend checks, TypeScript, dashboard build and truthfulness
audit passed. The three-part connected diagnostic passed again, including the
real settings UI warning at R=1 and its removal at R=10. The diagnostic still uses
in-app responses and is not a physical unattended-delivery or background-wake test.
See [ALERT_COVERAGE.md](ALERT_COVERAGE.md) for allocation and refresh limitations.

The dashboard CI initially could not start because its macOS 14 runner was
[retired by GitHub on November 2](https://github.blog/changelog/2026-10-01-github-actions-macos-14-runner-image-retirement/).
It now uses macOS 26, matching native CI. This infrastructure repair does not
waive screenshot checks or approve replacement baselines.

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
- Build 15 used an earliest-first 60-request queue that could starve a later
  dose. The subsequent source revision replaces this with complete 30-minute
  windows, reserving current/next first; see [ALERT_COVERAGE.md](ALERT_COVERAGE.md).
  That change still cannot guarantee background renewal or OS presentation.
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
