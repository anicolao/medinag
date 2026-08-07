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
  private let clock: any Clock
  private let eventStore: any MedicationEventStore
  private let notifications: any NotificationScheduling
  private let snoozeInterval: TimeInterval

  public init(
    clock: any Clock,
    eventStore: any MedicationEventStore,
    notifications: any NotificationScheduling,
    snoozeInterval: TimeInterval = 10 * 60
  ) {
    self.clock = clock
    self.eventStore = eventStore
    self.notifications = notifications
    self.snoozeInterval = snoozeInterval
  }

  @discardableResult
  public func requestNotificationReadiness(
    for events: [MedicationEvent]
  ) async throws -> Bool {
    let authorized = try await notifications.requestAuthorization()
    guard authorized else { return false }

    for event in events where event.status != .completed {
      try await notifications.schedule(event: event)
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
      try await notifications.scheduleRepeat(
        for: updated,
        at: clock.now.addingTimeInterval(snoozeInterval)
      )
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
