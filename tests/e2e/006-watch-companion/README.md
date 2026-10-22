# Watch companion: verification in progress

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
