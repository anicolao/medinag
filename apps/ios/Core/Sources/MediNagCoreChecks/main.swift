import Foundation
import MediNagCore

@main
struct MediNagCoreChecks {
  private static let now = Date(timeIntervalSince1970: 1_785_715_200)

  static func main() async throws {
    try await checkYesIWill()
    try await checkDefaultSnoozeInterval()
    try await checkYesIDid()
    try await checkNotificationReadiness()
    print("MediNagCoreChecks: 4 passed")
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
