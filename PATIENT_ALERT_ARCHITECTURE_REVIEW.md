# Patient alert architecture review

Draft for review — 25 November 2026

Reviewed implementation: `e15909d`, on `agent/local-alert-requirements`, also the source checkpoint for TestFlight build 18. This document proposes a direction; it does not authorize a rewrite or change the approved patient interactions.

## Recommendation

The concern is justified. We have made a small patient interface depend on two independent notification engines, several copies of response state, a custom phone–Watch synchronization protocol, and background maintenance. Much of that is necessary **for the architecture we chose**, not for the basic requirement of a loud scheduled alarm.

The biggest simplification is to have **one alarm owner and let the operating system present and silence the alarm**, including its supported Watch presentation. My recommendation is to prove that design on our actual phones and Watches using AlarmKit before rebuilding the native alerting layer. Keep the administrator dashboard, authentication, schedule publishing, and useful backend reporting. Do not start the entire project over.

There is a real product decision here. We previously prioritized exactly two equally weighted custom actions, independent alerts on both devices, and our own snooze timing. AlarmKit is closer to the latest priority—an intrusive alarm at a precise time—but it gives Apple control of parts of the UI. A rewrite cannot make those competing requirements disappear.

Neither design can promise that a person cannot ignore an alert, or that a powered-off device will ring. Because being 15 minutes late can have serious consequences, this remains an unproven alerting aid, not a sole safety guarantee. More logging does not change that limitation.

## 1. Requirements that determine the architecture

These are distinct requirements, not different descriptions of the same feature.

| Requirement | Architectural consequence |
| --- | --- |
| Ring at the patient's local dose time, without the app open | Register with the OS in advance; no network request or background wake at the deadline. |
| Break through silent mode and Sleep/other Focus modes | Use an authorized alarm API or approved Critical Alerts, not merely ordinary notifications. |
| Continue attracting attention when ignored | Establish the OS's actual ringing, dismissal, and repeat behavior. A notification in a list is not a continuously sounding alarm. |
| Exactly “Yes, I did” and “Yes, I will,” with equal prominence | Custom actionable notifications fit better than a system alarm with an OS-provided Stop control. |
| Notify both devices independently, even when disconnected | Two independently scheduled streams, with delayed cross-device cancellation when communication fails. |
| Respond on either device and immediately stop both | Requires communication, or a system-managed shared alarm experience. This conflicts with independent disconnected devices. |
| Snooze on the original dose grid | Custom timing: for an 08:00 dose and S=10 minutes, a tap at 08:12 means 08:20, not 08:22. |
| Only the latest dose matters | Old repeats and snoozes must expire before the successor; completion must never revive an older dose. |
| Keep working through app crashes and poor connectivity | Durable local schedule and responses; preinstalled OS alarms; network synchronization outside the ringing path. |
| Prove what happened | Separate registration, observed presentation, patient response, and cloud acknowledgment. None proves ingestion. |

R (unanswered repeat interval) and S (snooze interval) are administrator-wide settings. The existing bounded-coverage agreement is the first 30 minutes of each dose, with at least current and next windows preloaded. The latest wording, “always present,” may mean more than that. We must resolve that difference rather than quietly treating 30 minutes as indefinite protection.

The quiet app screen remains just the next dose, with early “Yes, I did” within 15 minutes. No connection dashboard belongs in the patient experience. Returning there after an in-app response was accepted for the test build because there is no supported general-purpose API to quit a foreground iPhone app on the user's behalf.

## 2. What is actually implemented

### Data and alarm ownership

```text
Administrator web UI
        |
        v
Firestore schedule + backend patient-local occurrence generation
        |
        v
iPhone: Firestore listeners -> cached events + local response outbox
        |                                   |
        v                                   v
iPhone OS notification queue       WatchConnectivity snapshots/commands
                                            |
                                            v
                                  Watch cache + pending local response
                                            |
                                            v
                                  Watch OS notification queue

Watch response -> local Watch cancellation -> phone -> phone cancellation
                                               -> Firestore -> administrator
```

The Watch has no Firebase client. It gets schedules through the phone, but rings from its own installed OS requests. This is therefore neither a simple mirrored-phone notification design nor a fully independent Watch service.

There is no APNs delivery path. Backend functions materialize occurrences, process incidents, and send administrator SMS; they do not make the phone or Watch sound at dose time.

### Scheduling

The backend supplies 15 patient-local calendar days of dose occurrences. The phone observes those records and passes snapshots to the Watch. Each device runs the same planner and registers actual, one-shot calendar notifications.

Each queue budgets 60 pending requests. At R=3 minutes, a complete dose window uses 11: T, T+3, …, T+30. Two windows use 22; five use 55. Capacity is spent on current and next first, then complete additional windows. Fifteen days of database records is **not** fifteen days of installed alerts.

R=1 requires 62 requests for two full windows, exceeding our budget. The administrator is warned, but can still save. Clients then install best-effort interleaved coverage rather than two complete windows. That is a deliberate current limitation, not a safe configuration enforced by the UI.

Ignoring a dose does not create an endless rolling sequence. Its unanswered repeats end at T+30. An explicit snooze can install its expiry after that boundary, unless superseded by the next dose. Past deadlines are not recreated on refresh. See [bounded coverage](https://github.com/anicolao/medinag/blob/e15909d3b01956db061746eb6418fb28d2b39d41/apps/ios/ALERT_COVERAGE.md), [planner](https://github.com/anicolao/medinag/blob/e15909d3b01956db061746eb6418fb28d2b39d41/apps/ios/Core/Sources/MediNagCore/ReminderPlan.swift), and [timing](https://github.com/anicolao/medinag/blob/e15909d3b01956db061746eb6418fb28d2b39d41/apps/ios/Core/Sources/MediNagCore/AlertTiming.swift).

### Sound, urgency, and interaction

Both devices register the two custom background actions. Phone notifications use the bundled `MediNagAlarm.caf`; Watch notifications use the default sound. Requests specify `.timeSensitive`. The current authorization requests ask for alert, badge, and sound—not Critical Alerts. The project does not configure the Time Sensitive or Critical Alerts signing entitlements. This is not an implementation of “highest available urgency.” See [registration and actions](https://github.com/anicolao/medinag/blob/e15909d3b01956db061746eb6418fb28d2b39d41/apps/ios/Shared/DeviceReminderNotifications.swift), [phone permissions](https://github.com/anicolao/medinag/blob/e15909d3b01956db061746eb6418fb28d2b39d41/apps/ios/MediNag/NotificationServices.swift), and [project configuration](https://github.com/anicolao/medinag/blob/e15909d3b01956db061746eb6418fb28d2b39d41/apps/ios/project.yml).

A preinstalled notification can be presented without the app running. Its background presentation does not itself run our code to install more requests. A real action launches the appropriate handler; that handler must save the response and update the local queue within a limited execution opportunity.

The phone saves a response to disk, applies it to the cached events, and reconciles its queue without first waiting for a server read. Synchronization follows. Watch responses similarly update local presentation/notifications and persist a command, then attempt phone delivery. Until the phone receives that command, it can legitimately continue executing its older queue. See [phone action handling](https://github.com/anicolao/medinag/blob/e15909d3b01956db061746eb6418fb28d2b39d41/apps/ios/MediNag/PhoneNotificationResponse.swift) and [Watch transport](https://github.com/anicolao/medinag/blob/e15909d3b01956db061746eb6418fb28d2b39d41/apps/ios/Shared/CompanionSession.swift).

### Refresh and recovery

Queue repair can run on activation, schedule changes, responses, notification callbacks, connectivity restoration, and actual background execution. iPhone requests both app refresh and processing slots; Watch requests refresh and handles WatchConnectivity background tasks. Cached repair precedes network refresh.

These requests improve recovery but cannot guarantee a run between doses. Apple's `earliestBeginDate` is a not-before date, not a promised execution time. The normal case of battery and connectivity does not turn it into a deadline. See [Apple's background scheduling contract](https://developer.apple.com/documentation/backgroundtasks/bgtaskrequest/earliestbegindate) and our [refresh coordinator](https://github.com/anicolao/medinag/blob/e15909d3b01956db061746eb6418fb28d2b39d41/apps/ios/MediNag/ReminderRefreshCoordinator.swift).

## 3. Why each complication exists—and whether to keep it

“Necessary” below means necessary to a stated requirement, not proof that the current implementation is correct.

| Component | Why it exists | Assessment and simplification |
| --- | --- | --- |
| Google sign-in and schedule selection | Associate this patient with the chosen administrator. | Necessary setup. Keep outside the alarm/response path once local enrollment is established. |
| Patient time zone and recurrence calculation | 08:00 means the patient's 08:00, including calendar changes. | Necessary policy. Prefer OS-native wall-clock recurrence where it matches that policy. |
| Server-generated occurrence records | Give dashboard and responses stable, shared dose identities. | Useful for reporting. Do not require fresh occurrence downloads for each recurring alarm to ring. |
| Durable downloaded schedule | Survive offline periods and process death. | Necessary. Retain one authoritative local store. |
| Bounded queue allocator | Fit repeated one-shot notifications into finite OS capacity. | Necessary for this notification strategy, not intrinsically for recurring OS alarms. Remove if AlarmKit proves sufficient. |
| OS inventory reconciliation | Detect rejected/missing/stale registrations. | Necessary verification. Keep a small adapter; readback proves registration, not sound. |
| Due-request retention | Avoid deleting an initial request just after its deadline but before OS consumption. | Necessary guard for the current rewrite-the-queue algorithm. Avoid that algorithm where possible. |
| Serialized updates and revision checks | Async refreshes can finish after newer responses. | One serialized local owner remains useful. Rebuilding the whole queue from many entry points creates extra races. |
| Response version and original tap time | Retry safely without double snoozing or moving the response timestamp. | Necessary for reliable reporting and anchored snoozes. Duplicate completion should be harmless. |
| Local response outbox | Cloud/network can be unavailable when the patient responds. | Necessary. Persist locally and send as soon as possible; never wait for cloud acknowledgment to silence locally. |
| Cache, outbox overlay, separate response-progress file | Prevent an old snapshot from reinstalling an already-cancelled alert, including after an outbox ACK/removal. | The protection is necessary; three independently managed representations are not. Use one transactional schedule/response store. |
| Independent Watch cache and queue | Make Watch alert without timely phone execution or routing. | Conditional on independent Watch alert ownership. Largest removable subsystem if system presentation is acceptable. |
| Watch optimistic response overlay | Let Watch respond before the phone acknowledges. | Necessary only with Watch-owned interactions/state. Disappears with no custom Watch alarm owner. |
| Watch commands, ACKs, retries, snapshot merging | Keep two devices consistent despite delayed/out-of-order delivery. | Conditional on dual ownership. This is distributed synchronization, not a two-button UI requirement. |
| App-delegate-owned background handlers | Actions can arrive without SwiftUI scenes being created. | Necessary for any retained app-handled action. Keep handlers independent of view construction and network startup. |
| Phone and Watch background maintenance | Repair and extend finite queues. | Best-effort recovery, never the foundation of the next alarm. Much less important with native recurrence. |
| Waiting for WatchConnectivity drainage | Avoid completing a Watch background task before work finishes. | Bounded completion is necessary; an unbounded wait is not. It can consume the execution allowance and get the process killed. |
| Anchored snooze calculation | Preserve the agreed T+n*S behavior. | Small necessary policy if retained. It is not the same as native snooze-from-tap. |
| Latest-dose retirement | Prevent yesterday's or an earlier dose returning. | Necessary in either design. Must also hold when our app gets no CPU at the successor deadline. |
| Local journal and administrator incident reporting | Diagnose failures and make risk visible. | Necessary observability, separate from the time-critical path. No routine disconnected/quiescent-state panic. |
| Legacy AlarmKit ledgers and activation bridges | Cancel alarms installed by older builds and preserve old routing interfaces. | Some temporary migration cleanup is justified. Permanent no-op bridges and obsolete abstractions are not. Remove after an explicit migration. |
| Old patient dashboard components and descriptions | Earlier product iterations exposed much more state. | Not required by today's UI. Delete unreachable components after call-site checks; rewrite misleading documentation. |

Concrete accumulation is visible in [NotificationServices](https://github.com/anicolao/medinag/blob/e15909d3b01956db061746eb6418fb28d2b39d41/apps/ios/MediNag/NotificationServices.swift): AlarmKit cleanup remains, while `alertingAlarmIDs` returns an empty set and `claimAlarmInteraction` returns nil. `AppViewModel` still calls those bridges. It constructs a `DoseCoordinator` without calling its action methods in that view model. These are candidates for removal, not reasons to add another layer.

The [Watch README](https://github.com/anicolao/medinag/blob/e15909d3b01956db061746eb6418fb28d2b39d41/apps/ios/MediNagWatch/README.md) still describes phone-owned AlarmKit, disabled offline actions, and no second notification stream. That is not the current implementation. Documentation drift has contributed to the confusion and must be corrected in the chosen implementation, not treated as a specification of what already works.

## 4. Which failures follow from the design

The [November 12 incident](https://github.com/anicolao/medinag/blob/e15909d3b01956db061746eb6418fb28d2b39d41/apps/ios/INCIDENT_2026-11-12.md) documents late/continued alerts after Watch responses and the resulting sequence of lifecycle, state-merging, persistence, and queue-race fixes. It also explicitly says the final notification-button walkthrough was not passing. An in-app demonstration is not equivalent evidence.

The earlier log audit found long Watch-to-phone response delays and a WatchConnectivity background watchdog termination. Those are historical observations, not a fresh November 25 health check. Delayed propagation explains how one device can continue nagging after the other accepted a response. It does not establish why every individual alert was late, unheard, or duplicated.

Three distinctions matter:

1. **Inherent coordination limitation:** a disconnected phone cannot know that the Watch was just answered. No improved ACK scheme makes that information arrive instantly. Requiring independent ringing plus instantaneous cross-device cancellation cannot be guaranteed during a partition.
2. **Fixable implementation defects:** unbounded background waits, stale snapshots overwriting responses, harmless superseded work becoming critical incidents, and mismatched backend coverage rules are bugs. They are not unavoidable Apple restrictions.
3. **Wrong alert primitive:** Time Sensitive notifications do not supply the alarm-like Focus/silent behavior we now prioritize. More retry machinery cannot correct that choice.

Apple allows users to disable Time Sensitive interruptions and requires its capability to be enabled. Critical Alerts bypass mute/Do Not Disturb but require an Apple-issued entitlement and user authorization; TestFlight is not a substitute for that entitlement. See [Time Sensitive behavior](https://developer.apple.com/documentation/usernotifications/unnotificationinterruptionlevel/timesensitive), [capability setup](https://developer.apple.com/videos/play/wwdc2021/10091/), and [Critical Alerts](https://developer.apple.com/documentation/usernotifications/unauthorizationoptions/criticalalert).

## 5. Simpler options

### A. Phone-owned AlarmKit alarms with system Watch presentation

**Recommended first experiment, not yet an approved replacement.**

AlarmKit on iOS 26 supports system alarms that break through Focus and silent mode, relative wall-clock schedules with weekly recurrence, custom phone alarm sounds, and presentation on a paired Watch. The OS handles the alarm experience rather than requiring us to deliver a sequence of ordinary notifications. See [Apple's AlarmKit introduction](https://developer.apple.com/videos/play/wwdc2025/230/).

Use one recurring alarm per published dose-time rule, not eleven notifications per occurrence. A missed response must not be necessary to install the next day's initial alarm. This removes the finite notification-window refill problem for initial recurring doses; it does **not** automatically solve ignored-alarm persistence, response reporting, or retirement of an older ringing/snoozed occurrence.

Important costs and unknowns:

- Apple's current alert API supplies the Stop control; its old custom-stop-button initializer is deprecated. We cannot promise the exact two equally weighted labels on either screen. See [current alarm presentation API](https://developer.apple.com/documentation/alarmkit/alarmpresentation/alert-swift.struct).
- A system Stop is not proof of “Yes, I did.” We must not silently mark medication taken because the user silenced an alarm. Any mapping needs explicit approval and truthful logging.
- Native post-alert snooze is an interval countdown. Our anchored T+n*S policy needs additional action logic if retained. AlarmKit countdown support requires its widget/Live Activity extension; Apple's sample warns that omitting it can cause unexpected dismissal and failure to alert. See [scheduling and countdown requirements](https://developer.apple.com/documentation/alarmkit/scheduling-an-alarm-with-alarmkit).
- Presentation on a paired Watch is not a promise of simultaneous, equally loud, independently functioning alarms on both devices. Test the actual paired/disconnected/wrist states.
- Confirm Stop and snooze preserve the next recurring occurrence, early completion skips only the intended occurrence, and newer doses retire older alarms **without requiring an app wake at that moment**. These are go/no-go tests, not assumptions.
- Verify how long an ignored alarm sounds, how it can be silenced, whether sound resumes, and which actions execute our intents. Do not assume the OS rings forever or exposes a callback for every presentation.
- Requires compatible devices/OS upgrades: the current project targets iOS 17 and watchOS 10. Raising the phone minimum to iOS 26 is a product change, not an invisible refactor.

This would replace the custom Watch alarm engine with the system experience; a separate Watch app may not be needed. Reusing the old AlarmKit code unexamined is not the proposal. Its remnants are not proof that today's required behavior has been validated.

### B. Phone-owned Critical Alert notifications with system forwarding

If exact custom response actions are non-negotiable, this is the smaller notification-based design to evaluate. Ask Apple for Critical Alerts approval, configure signing and authorization correctly, retain one phone queue and response store, and use supported system forwarding to Watch instead of a second Watch queue.

Apple documents that a background action on a phone-targeted notification forwarded to Watch is handled on the originating phone. That removes our custom Watch-to-phone command/ACK path for those actions, although physical-device routing and callback behavior still need proof. See [Watch notification action routing](https://developer.apple.com/documentation/watchos-apps/adding-actions-to-notifications-on-watchos).

This preserves custom actions but retains bounded queue allocation and refill risk. Critical Alert priority is not an indefinitely looping alarm. It cannot promise independent simultaneous presentation or Watch operation without the phone. The custom critical-sound API is not available on watchOS; do not promise the phone's custom sound on Watch. See [critical custom-sound availability](https://developer.apple.com/documentation/usernotifications/unnotificationsound/criticalsoundnamed(_:withaudiovolume:)).

If Apple does not grant the entitlement, ordinary/Time Sensitive notifications are not an equivalent substitute for the urgency requirement.

### C. Keep independent phone and Watch queues

Only choose this if independent device alerting is more important than simplicity and immediate cancellation everywhere. Consolidating stores, bounding background work, and fixing idempotency would improve it, but cannot eliminate cross-device propagation delays.

Adding Firebase directly to Watch would change the transport, not solve offline agreement. Adding APNs would introduce another delivery mechanism, contradict the local-only direction, and still not provide a hard delivery guarantee. Neither is the recommended simplification.

## 6. The proposed smaller native core

Regardless of A or B, retain only these responsibilities:

1. **Schedule importer:** authenticate/select once, download a versioned schedule, validate it, persist it. Treat patient wall time, daylight-saving transitions, travel, edits, and deletions explicitly.
2. **One local store:** schedule revision, occurrence identity, current response, original response timestamp, and an outgoing synchronization record. Save each local action atomically; do not independently maintain competing cache/progress/overlay truths.
3. **One OS adapter:** install/update/cancel stable alarm identifiers and verify inventory. Keep the old known-good schedule if replacement fails; record partial installation rather than claiming all-or-nothing success that the OS did not provide.
4. **Tiny response handler:** save locally, silence/snooze locally, return. Cloud synchronization starts as soon as possible and retries after interruption. Completion of an already-completed occurrence is a harmless duplicate; old snoozes cannot undo it.
5. **Synchronizer and evidence exporter:** upload responses and diagnostics independently. Report original tap time separately from phone receipt and server commit. A delayed synchronization is not proof the patient ignored the dose.
6. **Minimal UI:** initial setup, current two-action surface where supported/approved, and the agreed next-dose screen. No patient-facing machinery monitor.

The OS must already possess the necessary future alarm schedule before the app becomes quiet. Background refresh is for remote edits, reconciliation, and reporting, not permission to ring the next dose. No design can apply an administrator's new edit to a disconnected device before that edit reaches it.

Use native recurrence only for rules it actually represents. More complex future exceptions can justify bounded one-time alarms later; they do not justify building a general distributed scheduler now. Backend materialization may remain for history and SMS without being the device's sole source of future initial alarm registrations.

## 7. How to decide whether to restart

First build a narrow, throwaway AlarmKit feasibility target on a fresh branch. Use real administrator-created schedules and production-shaped data paths, not hardcoded demonstration doses. Prove system ringing and paired-Watch interaction before connecting every reporting feature.

The proof must answer all of these on physical hardware:

- Does a registered dose alarm sound on time under Sleep Focus, other Focus, silent mode, a locked phone, and suspended/terminated app conditions? Record conditions and failures; do not advertise universal reliability from a few successes.
- What exactly appears and sounds on phone and Watch when worn, unworn, locked, disconnected, and reconnected? Can the patient silence the shared experience without opening either app?
- What happens when the first dose is completely ignored, snoozed, or stopped? Does the next dose still alert with no intervening app execution? Does the older dose ever return?
- Can the approved actions and anchored snooze be implemented without turning the alarm handler into another network-dependent workflow? What happens if that handler crashes?
- What persists across reboot, permission withdrawal, time-zone changes, and an upgrade? Does stopping one recurrence leave tomorrow's alarm intact?

If AlarmKit meets the approved behavior, rebuild the alerting core around section 6 and retire the old Watch notification/transport engine. Keep proven authentication, backend, dashboard, and pure timing/identity rules where applicable. Do not wrap the existing thousand-line view model in a new interface and call that a restart.

If it fails an essential behavior, stop and review that result. Evaluate B if custom buttons win; retain C only with an explicit acceptance of its unavoidable delayed-cancellation behavior. Do not quietly fall back to a polished demonstration of weaker behavior.

Migration itself needs a small, explicit procedure. Old phone and Watch notification streams must be cancelled and their absence verified before enabling the replacement. A disconnected old Watch can keep its own queue: a phone-only upgrade is not proof of cleanup. Require a verified paired upgrade/cleanup step rather than temporarily running both systems and hoping duplicates disappear.

## 8. Evidence needed before calling it working

Retain separate evidence categories:

- **Configured:** the schedule/rule and permissions we intended.
- **Registered:** the OS accepted the alarm and its inventory contains it.
- **Observed:** a real OS callback or delivered-item observation, with its limited meaning recorded.
- **Heard/seen:** physical test observation of sound, haptics, and UI under named device conditions.
- **Responded:** actual action, occurrence identity, tap timestamp, and local cancellation/snooze result.
- **Synchronized:** receipt/commit timestamps and retries. Not a substitute for a patient response or presentation receipt.

Do not write a “delivered” event at an expected deadline and pretend the OS confirmed it. A pending request is not proof of sound; no callback while suspended is not proof of silence. Unknown delivery remains unknown.

Automated stories must use the real web UI, isolated Firebase Auth/Firestore emulators, actual native registration, actual system alerts/buttons, and real response writes back to the dashboard. Accelerating the clock is acceptable when it changes time rather than fabricating behavior. An accelerated Simulator story cannot prove physical Focus bypass, sound, background budgets, or hours of endurance; those require a separate physical-device run.

Test restart boundaries explicitly: after saving the tap but before cancelling; after cancelling but before uploading; after server commit but before the acknowledgment reaches the client. Restart the app process and verify no old alarm is resurrected and no response is applied twice. Include a completely ignored dose followed by the next dose with no manually triggered refresh.

Keep the repository's event-driven waits and exact approved screenshot comparisons. Do not fix a timing failure by inserting a sleep, or a visual failure by loosening pixel tolerance. Screenshots validate the UI; timing and lifecycle evidence validate alert behavior. Both are required, and a failed system-action story remains a failure.

## 9. Decisions requested

1. **Primary tradeoff:** accept Apple's alarm/Stop interface if it gives the stronger alarm experience, or retain the exact two custom medication responses? Silencing and reporting medication taken must remain distinct unless explicitly agreed otherwise.
2. **Device ownership:** accept one phone-owned system alarm presented through Apple's supported Watch experience, or insist on independent simultaneous device alerts despite delayed cancellation when disconnected?
3. **Repeat and snooze:** does the first-30-minutes agreement still apply, or must alerting persist until response/the next dose? Retain anchored snooze, or accept native snooze semantics if that removes custom action scheduling?
4. **Scope:** approve the physical AlarmKit feasibility proof first—not a full rewrite—then choose the implementation from its evidence, including OS-version requirements.

My recommendation is to prioritize the strongest system alarm experience and single ownership, prove it on the actual devices, and only then rebuild the small native core. The current complexity should not be preserved merely because we have already written it.
