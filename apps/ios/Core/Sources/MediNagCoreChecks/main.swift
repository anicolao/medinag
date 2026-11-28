import Foundation
import MediNagCore

@main
struct MediNagCoreChecks {
  private static let now = Date(timeIntervalSince1970: 1_785_715_200)

  static func main() async throws {
    try await checkResponseIdentifiers()
    try await checkYesIWill()
    try await checkDefaultSnoozeInterval()
    try await checkConfiguredSnoozeRestoresAfterRelaunch()
    try await checkMaximumReminderCount()
    try await checkYesIDid()
    try await checkNotificationReadiness()
    try await checkReminderPlan()
    try await checkAlarmKitPolicy()
    print("MediNagCoreChecks: 9 passed")
  }

  private static func checkAlarmKitPolicy() async throws {
    let origin = now
    try await expect(AlarmKitPolicy.gridDeadline(origin: origin, now: origin.addingTimeInterval(12 * 60), interval: 10 * 60)
      == origin.addingTimeInterval(20 * 60), "08:12 snooze for an 08:00 dose must target 08:20")
    try await expect(AlarmKitPolicy.gridDeadline(origin: origin, now: origin.addingTimeInterval(3 * 60), interval: 10 * 60)
      == origin.addingTimeInterval(10 * 60), "An ignored repeat does not buy a new snooze interval")
    let event = pendingEvent()
    try await expect(AlarmKitPolicy.canCompleteEarly(event, at: event.scheduledTime.addingTimeInterval(-900)),
      "Early completion starts exactly fifteen minutes before the actual dose")
    try await expect(!AlarmKitPolicy.canCompleteEarly(event, at: event.scheduledTime.addingTimeInterval(-901)),
      "Earlier than fifteen minutes must offer no dose action")
    var completed = event
    completed.status = .completed
    try await expect(AlarmKitPolicy.latestDue(in: [completed], at: event.scheduledTime) == nil,
      "A completed latest occurrence must not become actionable")
    let dose = event.scheduledTime
    let block = AlarmKitPolicy.retryPlan(events: [event], at: dose.addingTimeInterval(-60), repeatInterval: 180)
    try await expect(block.map(\.deadline) == (0...10).map { dose.addingTimeInterval(Double($0) * 180) },
      "Without any tap, independent alarms cover T, T+3, T+6 through T+30")
    let next = MedicationEvent(id: "next-dose", scheduleID: "next", medicationName: "Next",
      scheduledTime: dose.addingTimeInterval(3600), status: .pending, snoozeCount: 0)
    let two = AlarmKitPolicy.retryPlan(events: [event, next], at: dose.addingTimeInterval(-60), repeatInterval: 60)
    try await expect(two.count == 62 && two.filter { $0.eventID == next.id }.count == 31,
      "Even one-minute repeats must cover two complete 30-minute blocks")
    var snoozed = event
    snoozed.status = .snoozed
    snoozed.snoozedUntil = dose.addingTimeInterval(20 * 60)
    let snoozeBlock = AlarmKitPolicy.retryPlan(events: [snoozed, next],
      at: dose.addingTimeInterval(12 * 60), repeatInterval: 180)
    try await expect(snoozeBlock.first?.deadline == dose.addingTimeInterval(20 * 60),
      "08:12 snooze suppresses earlier retries and independently arms 08:20")
    let retired = AlarmKitPolicy.retryPlan(events: [event, next], at: next.scheduledTime, repeatInterval: 180)
    try await expect(retired.allSatisfy { $0.eventID == next.id }, "Newer dose retires all old retries")
    let done = AlarmKitPolicy.retryPlan(events: [completed, next], at: dose, repeatInterval: 180)
    try await expect(done.allSatisfy { $0.eventID == next.id }, "Completion cancels the whole dose block")
    let close = MedicationEvent(id: "close-dose", scheduleID: "close", medicationName: "Close",
      scheduledTime: dose.addingTimeInterval(5 * 60), status: .pending, snoozeCount: 0)
    let overlap = AlarmKitPolicy.retryPlan(events: [event, close], at: dose.addingTimeInterval(-60), repeatInterval: 180)
    try await expect(overlap.filter { $0.eventID == event.id }.allSatisfy { $0.deadline < close.scheduledTime },
      "No old-dose retries can be registered at or beyond the successor")
    let sparse = AlarmKitPolicy.singleDosePlan(events: [event, next], at: dose.addingTimeInterval(-60), limit: 2)
    try await expect(sparse.count == 2 && sparse.map(\.deadline) == [dose, next.scheduledTime],
      "Reliability trial has exactly one alarm at each original dose time, no dense retries")
    let late = AlarmKitPolicy.singleDosePlan(events: [event, next], at: dose.addingTimeInterval(600))
    try await expect(late.map(\.deadline) == [next.scheduledTime],
      "Reliability trial must not replay missed doses or register catch-up alerts")
    try await expect(AlarmKitPolicy.singleDosePlan(events: [completed, next], at: dose.addingTimeInterval(-60))
      .map(\.eventID) == [next.id], "Completed occurrences must not be rearmed in the trial")
    try await expect(AlarmKitPolicy.singleDosePlan(events: [event, next], at: dose.addingTimeInterval(-60), limit: 1)
      .map(\.eventID) == [event.id], "Trial capacity must reserve earliest actual dose first")
    try await expect(AlarmKitPolicy.singleDosePlan(events: [next, event], at: dose.addingTimeInterval(-60))
      .map(\.eventID) == [event.id], "The default trial plan must contain ONLY the next alert, not future backups")
  }

  private static func checkResponseIdentifiers() async throws {
    try await expect(
      DoseResponse.yesIWill.rawValue == "yesIWill",
      "Yes, I will must retain its notification routing identifier"
    )
    try await expect(
      DoseResponse.yesIDid.rawValue == "yesIDid",
      "Yes, I did must retain its notification routing identifier"
    )
  }

  private static func checkConfiguredSnoozeRestoresAfterRelaunch() async throws {
    var event = pendingEvent()
    event.status = .snoozed
    event.snoozeCount = 1
    event.lastSnoozedAt = now
    let notifications = RecordingNotifications()
    let coordinator = DoseCoordinator(
      clock: FixedClock(now: now),
      eventStore: RecordingEventStore(event: event),
      notifications: notifications,
      snoozeInterval: 15 * 60
    )

    _ = try await coordinator.requestNotificationReadiness(for: [event])

    try await expect(
      await notifications.repeats == [
        .init(eventID: event.id, date: now.addingTimeInterval(15 * 60))
      ],
      "A relaunched app must restore a snoozed notification using the administrator's interval"
    )
  }

  private static func checkMaximumReminderCount() async throws {
    var event = pendingEvent()
    event.status = .snoozed
    event.snoozeCount = 2
    event.lastSnoozedAt = now
    let notifications = RecordingNotifications()
    let coordinator = DoseCoordinator(
      clock: FixedClock(now: now),
      eventStore: RecordingEventStore(event: event),
      notifications: notifications,
      snoozeInterval: 10 * 60,
      maximumReminderCount: 3
    )

    let updated = try await coordinator.respond(.yesIWill, to: event)

    try await expect(updated.snoozeCount == 3, "The final response must still be recorded")
    try await expect(
      await notifications.repeats.count == 1,
      "The escalation reminder limit must not silently disable patient notifications"
    )
  }

  private static func checkReminderPlan() async throws {
    let event = pendingEvent()
    let plan = ReminderPlan(events: [event], now: now.addingTimeInterval(-60), snoozeInterval: 600, capacity: 4)
    try await expect(plan.occurrences.map(\.date) == [0, 180, 360, 540].map { now.addingTimeInterval(Double($0)) },
      "The OS queue must contain the dose and three-minute follow-ups before delivery")
    try await expect(plan.coveredThrough == now.addingTimeInterval(719), "Coverage must end before the first omitted reminder")
    let overdue = ReminderPlan(events: [event], now: now.addingTimeInterval(200), snoozeInterval: 600, capacity: 4)
    try await expect(overdue.occurrences.first?.date == now.addingTimeInterval(360),
      "Refreshing after dismissal must retain the original three-minute cadence, not fabricate a late first dose")
    var snoozed = event
    snoozed.status = .snoozed
    snoozed.lastSnoozedAt = now
    snoozed.snoozeCount = 5
    let snooze = ReminderPlan(events: [snoozed], now: now, snoozeInterval: 600, capacity: 4)
    try await expect(snooze.occurrences.first?.date == now.addingTimeInterval(600), "Explicit snooze postpones the whole nag sequence")
    try await expect(Set(snooze.occurrences.map(\.identifier)).isDisjoint(with: Set(plan.occurrences.map(\.identifier))),
      "Snoozing must replace every old notification identifier")
    snoozed.status = .completed
    try await expect(ReminderPlan(events: [snoozed], now: now, snoozeInterval: 600).occurrences.isEmpty,
      "Completion must remove the whole nag sequence")
  }

  private static func checkDefaultSnoozeInterval() async throws {
    let event = pendingEvent()
    let store = RecordingEventStore(event: event)
    let notifications = RecordingNotifications()
    let coordinator = DoseCoordinator(
      clock: FixedClock(now: now),
      eventStore: store,
      notifications: notifications
    )

    _ = try await coordinator.respond(.yesIWill, to: event)

    try await expect(
      await notifications.repeats == [
        .init(
          eventID: event.id,
          date: now.addingTimeInterval(DoseCoordinator.defaultSnoozeInterval)
        )
      ],
      "The current default must schedule the repeat 10 minutes later"
    )
  }

  private static func checkYesIWill() async throws {
    let event = pendingEvent()
    let store = RecordingEventStore(event: event)
    let notifications = RecordingNotifications()
    let coordinator = DoseCoordinator(
      clock: FixedClock(now: now),
      eventStore: store,
      notifications: notifications,
      snoozeInterval: 600
    )

    let updated = try await coordinator.respond(.yesIWill, to: event)

    try await expect(updated.status == .snoozed, "Yes, I will must snooze")
    try await expect(updated.snoozeCount == 1, "Snooze count must increment")
    try await expect(updated.lastSnoozedAt == now, "Snooze time must use the injected clock")
    let repeats = await notifications.repeats
    try await expect(
      repeats == [.init(eventID: event.id, date: now.addingTimeInterval(600))],
      "Exactly one repeat must be scheduled at the configured interval"
    )
    try await expect(
      await notifications.cancelledEventIDs == [],
      "Snoozing must not cancel the event"
    )
  }

  private static func checkYesIDid() async throws {
    let event = pendingEvent()
    let store = RecordingEventStore(event: event)
    let notifications = RecordingNotifications()
    let coordinator = DoseCoordinator(
      clock: FixedClock(now: now),
      eventStore: store,
      notifications: notifications
    )

    let updated = try await coordinator.respond(.yesIDid, to: event)

    try await expect(updated.status == .completed, "Yes, I did must complete")
    try await expect(updated.completedAt == now, "Completion must use the injected clock")
    try await expect(
      await notifications.cancelledEventIDs == [event.id],
      "Completion must cancel further nags"
    )
    try await expect(await notifications.repeats == [], "Completion must not schedule a repeat")
  }

  private static func checkNotificationReadiness() async throws {
    let pending = pendingEvent()
    var completed = pendingEvent(id: "completed-dose")
    completed.status = .completed
    completed.completedAt = now
    let store = RecordingEventStore(event: pending)
    let notifications = RecordingNotifications()
    let coordinator = DoseCoordinator(
      clock: FixedClock(now: now),
      eventStore: store,
      notifications: notifications
    )

    let ready = try await coordinator.requestNotificationReadiness(
      for: [pending, completed]
    )

    try await expect(ready, "Authorized notifications must report ready")
    try await expect(
      await notifications.scheduled == [
        .init(eventID: pending.id, date: pending.scheduledTime)
      ],
      "Only unfinished events may be scheduled, at the medication time"
    )
  }

  private static func pendingEvent(id: String = "morning-dose") -> MedicationEvent {
    MedicationEvent(
      id: id,
      scheduleID: "morning-schedule",
      medicationName: "Morning Prescription Doses",
      scheduledTime: now,
      status: .pending,
      snoozeCount: 0
    )
  }

  private static func expect(
    _ condition: @autoclosure () async -> Bool,
    _ message: String
  ) async throws {
    guard await condition() else { throw CheckFailure(message: message) }
  }
}

private struct CheckFailure: Error, CustomStringConvertible {
  let message: String
  var description: String { message }
}

private struct FixedClock: Clock {
  let now: Date
}

private actor RecordingEventStore: MedicationEventStore {
  private var event: MedicationEvent

  init(event: MedicationEvent) {
    self.event = event
  }

  func snooze(eventID: String, at date: Date) async throws -> MedicationEvent {
    event.status = .snoozed
    event.snoozeCount += 1
    event.lastSnoozedAt = date
    return event
  }

  func complete(eventID: String, at date: Date) async throws -> MedicationEvent {
    event.status = .completed
    event.completedAt = date
    return event
  }
}

private actor RecordingNotifications: NotificationScheduling {
  struct Scheduled: Equatable {
    let eventID: String
    let date: Date
  }

  struct Repeat: Equatable {
    let eventID: String
    let date: Date
  }

  private(set) var scheduled: [Scheduled] = []
  private(set) var repeats: [Repeat] = []
  private(set) var cancelledEventIDs: [String] = []

  func requestAuthorization() async throws -> Bool { true }

  func schedule(event: MedicationEvent) async throws {
    scheduled.append(.init(eventID: event.id, date: event.scheduledTime))
  }

  func scheduleRepeat(for event: MedicationEvent, at date: Date) async throws {
    repeats.append(.init(eventID: event.id, date: date))
  }

  func cancel(eventID: String) async {
    cancelledEventIDs.append(eventID)
  }
}
