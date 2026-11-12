# Bounded local-alert coverage

## Requirement agreed on 2026-11-11

Preload the initial alert and repeats during the first 30 minutes after each
dose time. Reserve the current unanswered dose and the next upcoming dose first;
use remaining space for complete further windows. Ignoring the current dose must
not prevent the next dose's first alert. A newer dose retires every older dose.

The phone and Watch each maintain their own real local-notification queue. No
APNs, server-generated delivery, silent pushes, or fabricated delivery callbacks
are used to implement this policy.

## Allocation

The application conservatively budgets 60 pending requests per device, below
Apple's documented legacy iOS 64-request limit; it verifies the actual inventory
rather than assuming registration succeeded on either platform. A window includes its initial request and every R
minutes through T+30 minutes, inclusive when R divides 30. With R=3, the deadlines
are T, T+3, ..., T+30: eleven requests per window, 22 for two windows. Five full
windows fit in 55 slots; the remaining five are not used for a partial sixth
window. Calendar distance between doses does not consume slots.

With R=1, two windows need 62 slots. The administrator sees a warning immediately
on choosing this setting, before saving. Saving remains allowed, but the clients
register best-effort interleaved requests and report insufficient coverage, not a
healthy two-window queue. The estimate is conservative: a successor inside 30
minutes cuts off its predecessor and may reduce the actual requirement. The
client checks its actual plan independently of the web warning.

Completed doses are removed. Past deadlines are not replayed on refresh. After
T+30, an ignored dose does not get an endlessly extended window. A real snooze
keeps its expiry on the original T+n*S grid; it does not start a fresh 30-minute
window. An explicit snooze expiry beyond T+30 gets one expiry request, unless a
new dose supersedes it. Snooze settings over 30 minutes have a separate warning.

Occurrence materialization supplies 15 patient-local calendar days, enough for
two future occurrences even for a once-weekly schedule after today's dose passed.
This is a data horizon, not a promise that every occurrence has OS requests.
An empty/unavailable schedule cannot be made safe by inventing another dose.

## Refresh opportunities

Before a network operation, maintenance repairs the queue from durable cached
events, applying saved responses so that an offline answer is not undone. Online
maintenance then fetches real Firestore data, installs the corrected queue, saves
the refreshed cache, and passes it to the existing Watch connection when present.
Queue inventory is read back from the OS and missing future requests are errors.

On iPhone, request both BGAppRefresh and BGProcessing. Prefer the earliest of
15 minutes from now, five minutes before the next dose, and 15 minutes before the
first unprotected deadline; never move an already-earlier pending request later.
Processing does not require charging or a network because cached repair works
offline. Request again after a real queue reconciliation and actual background
execution. Activation, a real notification action/open/dismiss callback, foreground
notification presentation, and restored connectivity also give repair opportunities.
A background-presented notification alone does **not** execute application code.

On Watch, request a WatchKit background refresh using the same preferred-time
policy. Repair its independent cached queue first, then request actual phone data
through WatchConnectivity. Activation, actions, and real connectivity transfers
provide additional opportunities. None is a substitute for preloading both windows.

## What cannot be promised

An iOS/WatchOS preferred background date is not a deadline. The system chooses
whether and when to grant time. Having battery, being on, and having connectivity
does not guarantee a run between doses or establish a 90% wake success rate.
Force-quitting, permissions, Focus/silent settings, device shutdown, OS decisions,
and exhausted queues remain material limitations. Do not call this a medical-grade
delivery guarantee. Do not use unrelated background modes to manufacture CPU time.

The already registered current/next windows need neither a patient response nor
a background wake to become eligible for OS presentation. If the app never runs
again, protection stops after the last preloaded window. Even a correctly pending
request is not proof that the patient heard or saw it.

Apple references:

- [earliestBeginDate](https://developer.apple.com/documentation/backgroundtasks/bgtaskrequest/earliestbegindate)
- [Documented notification limit](https://developer.apple.com/documentation/UIKit/UILocalNotification)
- [Processing requests](https://developer.apple.com/documentation/backgroundtasks/bgprocessingtaskrequest)
- [Watch background tasks](https://developer.apple.com/documentation/WatchKit/using-background-tasks)

## Evidence required

Unit checks assert exact deadlines, capacity failures, successor cutoffs, anchored
snoozes, and refresh preferences. They are not notification-delivery E2E tests.
Connected tests must create schedules through the real administrator UI and use
Firebase emulators, production registration/response paths, and actual OS alerts.
Advancing/scaling the clock is permitted; inventing alerts or successful wake-ups
is not. An in-app response diagnostic does not prove a notification-button action.

For physical-device assurance, leave the phone/Watch backgrounded across several
doses, ignore one complete window, and confirm the next dose independently alerts.
Capture expected versus observed timestamps and actual background-start records.
Repeat with an action on each device, no connectivity, and device restart. Count
missed/late alerts and ungranted refreshes rather than excluding them. The JSONL
journal records requests, registration acceptance, observed pending/delivered
inventory, actual callbacks, and responses separately. A registration acceptance
or a disappeared request must never be reported as proof of delivery.
