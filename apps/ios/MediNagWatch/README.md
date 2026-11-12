# Apple Watch companion

Install the iPhone TestFlight build, then install MediNag from the iPhone Watch
app's Available Apps section (or enable Automatic App Install). Sign in with
Google and follow a schedule on iPhone. Open MediNag on the paired Watch.

The Watch shows the actual followed medication events, their patient-local dose
times, snooze counts, and recent completions. Both response buttons have the same
style; neither is a default. Responses become available when the dose or its
configured snooze is due. The Watch sends the displayed event version to iPhone
over WatchConnectivity. The phone validates identity and plan, commits the same
production Firestore transaction used by phone responses, reconciles AlarmKit,
and acknowledges the result. Dose status follows the server-acknowledged event;
the final success message also waits for alarm reconciliation. Neither is an
optimistic local response. A stale response cannot double-snooze or undo completion.

On first launch, use **Refresh from iPhone** if the schedule has not appeared.
Foreground activation actively requests current data; background context delivery
is opportunistic. The explicit refresh requests a server-backed read through the
phone. No uniform two-second promise is made for first-time OS pairing/delivery.

This is deliberately a dependent companion, not an independent Watch client:

- Google authentication and plan selection happen on iPhone. No tokens are sent
  to Watch, and Firebase is not linked into the Watch executable.
- When iPhone is unreachable, cached schedule data is labelled disconnected and
  response buttons are disabled. No silent/optimistic offline completion queue.
- The iPhone owns the alarms. iOS 26 AlarmKit can mirror them to a paired Watch;
  this app does not manufacture a second stream of Watch notifications or promise
  continuous Watch haptics/custom Watch audio. Apple controls alarm routing.
- Tapping a mirrored alarm is system-controlled. Open MediNag on Watch to respond
  there; automatic navigation from that mirrored alarm is not claimed.
- Failed phone-side Watch synchronization or responses use the existing
  administrator incident/SMS path. Loss of connectivity cannot itself contact
  the administrator; the independent backend overdue-dose watchdog still runs.

## Verification

Status: the companion is available for manual TestFlight testing, but the new
paired CI/visual gate is not green. Prior local runs completed the real closed
loop. Subsequent clean runs have failed the two-second first-sync or alarm-count
conditions, and native screenshot framing has required further harness work.
There are no approved native US-006 baselines yet. See the
[verification status](../../../tests/e2e/006-watch-companion/README.md).

`npm run ios:e2e:watch` creates fresh paired iPhone 17/iOS 26.5 and Apple Watch
Series 11 46mm/watchOS 26.5 Simulators and a fresh Firebase emulator environment.
The administrator publishes through the web UI, the patient signs in/follows on
iPhone, and the Watch exchanges real WatchConnectivity messages. Snooze must
produce a real repeat iPhone alarm, and completion must return to the dashboard.
There is no injected Watch identity, schedule, response, or connection.

Walkthroughs capture the native Watch application scroll surface below its
120-pixel navigation header. watchOS does not support Simulator status-bar
overrides, so the system clock/header is excluded at capture, without replacing
or normalizing any retained application pixels.
Individual button and acknowledgement captures retain the actual native control
pixels so scrolling cannot cut off the response choices in the walkthrough.
Condition waits remain capped at two seconds; native PNG comparison is exact.

Physical verification is still required for Watch installation, alarm mirroring,
sound/haptics, wrist detection, locked-phone routing, and responding while the
phone app is suspended or terminated. A Simulator result does not prove these
hardware/OS behaviours.
