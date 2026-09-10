import Foundation

public protocol Clock: Sendable {
  var now: Date { get }
}

public struct SystemClock: Clock {
  public init() {}

  public var now: Date { Date() }
}

public protocol MedicationEventStore: Sendable {
  func snooze(eventID: String, at date: Date) async throws -> MedicationEvent
  func complete(eventID: String, at date: Date) async throws -> MedicationEvent
}

public protocol NotificationScheduling: Sendable {
  func requestAuthorization() async throws -> Bool
  func schedule(event: MedicationEvent) async throws
  func scheduleRepeat(for event: MedicationEvent, at date: Date) async throws
  func cancel(eventID: String) async
}

public actor DoseCoordinator {
  public static let defaultSnoozeInterval: TimeInterval = 10 * 60
  public static let defaultMaximumReminderCount = 3

  private let clock: any Clock
  private let eventStore: any MedicationEventStore
  private let notifications: any NotificationScheduling
  private let snoozeInterval: TimeInterval
  private let maximumReminderCount: Int

  public init(
    clock: any Clock,
    eventStore: any MedicationEventStore,
    notifications: any NotificationScheduling,
    snoozeInterval: TimeInterval = DoseCoordinator.defaultSnoozeInterval,
    maximumReminderCount: Int = DoseCoordinator.defaultMaximumReminderCount
  ) {
    self.clock = clock
    self.eventStore = eventStore
    self.notifications = notifications
    self.snoozeInterval = snoozeInterval
    self.maximumReminderCount = max(1, maximumReminderCount)
  }

  @discardableResult
  public func requestNotificationReadiness(
    for events: [MedicationEvent]
  ) async throws -> Bool {
    let authorized = try await notifications.requestAuthorization()
    guard authorized else { return false }

    for event in events where event.status != .completed {
      if event.status == .snoozed {
        guard event.snoozeCount < maximumReminderCount else { continue }
        let snoozedAt = event.lastSnoozedAt ?? event.scheduledTime
        try await notifications.scheduleRepeat(
          for: event,
          at: snoozedAt.addingTimeInterval(snoozeInterval)
        )
      } else {
        try await notifications.schedule(event: event)
      }
    }
    return true
  }

  @discardableResult
  public func respond(
    _ response: DoseResponse,
    to event: MedicationEvent
  ) async throws -> MedicationEvent {
    switch response {
    case .yesIWill:
      let updated = try await eventStore.snooze(
        eventID: event.id,
        at: clock.now
      )
      if updated.snoozeCount < maximumReminderCount {
        try await notifications.scheduleRepeat(
          for: updated,
          at: clock.now.addingTimeInterval(snoozeInterval)
        )
      }
      return updated

    case .yesIDid:
      let updated = try await eventStore.complete(
        eventID: event.id,
        at: clock.now
      )
      await notifications.cancel(eventID: event.id)
      return updated
    }
  }
}
