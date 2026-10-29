# Watch companion: verification in progress

## Current design supersedes the earlier evidence below

The current source replaces AlarmKit with independent actionable notification
queues and a one-dose Watch screen. The claims and native tests have been
updated accordingly; earlier screenshots and passing alarm runs below do not
validate this implementation. See [the physical-device procedure](../../../WATCH_NOTIFICATION_TESTING.md).
No new screenshot baseline or simultaneous audible-delivery claim is approved.
The latest local run on 2026-10-28 passed dashboard publication, phone setup, and
the Watch dose/response-controls steps, but timed out awaiting the real snooze
acknowledgement within the two-second condition. That is still a failing E2E run.
Twenty-four native unit tests and eight portable core checks pass, including cached
reminder retention during phone startup. These are not a passing Watch E2E run.
The next-dose cutoff, response acknowledgements/recovery, background reachability
handling, and pending-count race fixes are not yet in TestFlight: Apple requires
the Account Holder to accept an updated Program License Agreement before upload.

## Earlier build 10 evidence (historical only)

The Watch companion is implemented and uploaded for manual testing in TestFlight
0.1.0 (10). This is **not yet an approved end-to-end walkthrough** or a green CI
result.

The implementation uses real WatchConnectivity, the paired phone's Firebase
authentication, server-backed Firestore reads, transactional patient responses,
and the production AlarmKit scheduler. Watch state is not seeded or substituted.

## What has been verified

- The signed iPhone archive embeds the signed Watch companion with matching build numbers.
- Apple processed build 10 and assigned it to the Internal TestFlight group.
- Ten native unit tests and seven portable core checks passed locally.
- Earlier paired local runs completed dashboard publication, phone following,
  Watch snooze, real repeat iPhone alarm delivery, Watch completion, and the
  completed event returning to the administrator dashboard.

## What is not yet verified

The latest clean runs are not consistently green. Failures include first-time
Watch data delivery exceeding a two-second condition, and an iPhone alarm-count
assertion after a stalled Simulator run. Watch navigation/screenshot framing also
needs confirmation. The test now exercises the visible Refresh from iPhone action
and uses real Digital Crown gestures; that final revision has not completed a
passing clean run.

There are **no approved native screenshot baselines** for this story.
[Diagnostic captures](diagnostics/) come from a prior passing functional run and
are not proof that the current test revision passes. They are deliberately kept
outside the baseline directory. Expected claims in `claims.json` describe the
intended test, not successful results.

The CI job retains the zero-pixel gate and two-second conditions. It must not go
green by skipping tests, lengthening deadlines, manufacturing state, or treating
these diagnostic captures as approved baselines. The export script refuses to
generate a checked-off walkthrough from failed or skipped native test results.

## Next verification

Run `npm run ios:e2e:watch` on the pinned paired Simulators. Resolve the actual
failing conditions, confirm the real control captures, and approve native
baselines only after reproducible passing runs. Then generate this walkthrough
from the successful XCTest attachments and claims manifest.

Separately test actual Watch installation, alarm mirroring, sound/haptics,
locked-phone routing, disconnection, and responses with the phone app suspended
or terminated. Simulator screenshots do not prove these hardware behaviours.
