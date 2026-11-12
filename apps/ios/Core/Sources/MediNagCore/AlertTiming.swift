import Foundation

/// All snoozes stay on the medication's original time grid. A repeat, retry,
/// reconnect or late response must never buy a new interval from receipt time.
public enum AlertTiming {
  public static func snoozeDeadline(for event: MedicationEvent, respondedAt: Date,
                                    interval: TimeInterval) -> Date {
    let step = max(1, event.snoozeIntervalSeconds ?? interval)
    let slot = max(1, floor(respondedAt.timeIntervalSince(event.scheduledTime) / step) + 1)
    return event.scheduledTime.addingTimeInterval(slot * step)
  }

  public static func reminder(for event: MedicationEvent, snoozeInterval: TimeInterval) -> Date {
    if event.status == .snoozed, let deadline = event.snoozedUntil { return deadline }
    guard event.status == .snoozed, let tap = event.lastSnoozedAt else { return event.scheduledTime }
    return snoozeDeadline(for: event, respondedAt: tap, interval: snoozeInterval)
  }

  public static func applyingPolicy(to events: [MedicationEvent], previous: [MedicationEvent],
    at now: Date, snoozeInterval: TimeInterval, repeatInterval: TimeInterval) -> [MedicationEvent] {
    events.map { raw in
      let prior = previous.first { $0.id == raw.id }
      var event = prior.map { raw.preservingResponseProgress(from: $0) } ?? raw
      if let prior, event.scheduledTime <= now {
        event.snoozeIntervalSeconds = prior.snoozeIntervalSeconds ?? snoozeInterval
        event.repeatIntervalSeconds = prior.repeatIntervalSeconds ?? repeatInterval
      } else {
        event.snoozeIntervalSeconds = snoozeInterval
        event.repeatIntervalSeconds = repeatInterval
      }
      if let prior, event.hasSameResponseVersion(as: prior),
        event.lastSnoozedAt == prior.lastSnoozedAt
          || (event.lastSnoozedAt.flatMap { tap in prior.lastSnoozedAt.map { abs(tap.timeIntervalSince($0)) < 0.001 } } ?? false) {
        event.snoozedUntil = prior.snoozedUntil
      }
      return event
    }
  }

  public static func canComplete(_ event: MedicationEvent, among events: [MedicationEvent],
                                 at now: Date, snoozeInterval: TimeInterval) -> Bool {
    guard DoseWindow.isActive(event, among: events, at: now) else { return false }
    if event.scheduledTime > now { return event.scheduledTime.timeIntervalSince(now) <= 900 }
    return reminder(for: event, snoozeInterval: snoozeInterval) <= now
  }
}

/// Durable data for one real tap, not a replacement event repository. The same
/// timestamp and version are reused until the production repository confirms it.
public struct LocalDoseResponse: Codable, Sendable, Identifiable {
  public let id: String
  public let patientID: String
  public let administratorID: String
  public let event: MedicationEvent
  public let response: DoseResponse
  public let respondedAt: Date
  public let snoozeInterval: TimeInterval

  public init(id: String = UUID().uuidString, patientID: String, administratorID: String,
              event: MedicationEvent, response: DoseResponse, respondedAt: Date,
              snoozeInterval: TimeInterval) {
    self.id = id; self.patientID = patientID; self.administratorID = administratorID
    self.event = event; self.response = response; self.respondedAt = respondedAt
    self.snoozeInterval = snoozeInterval
  }

  public var updatedEvent: MedicationEvent {
    var updated = event
    switch response {
    case .yesIDid:
      updated.status = .completed; updated.completedAt = respondedAt
    case .yesIWill:
      updated.status = .snoozed; updated.snoozeCount += 1; updated.lastSnoozedAt = respondedAt
      updated.snoozedUntil = snoozeDeadline
    }
    return updated
  }

  public var snoozeDeadline: Date {
    AlertTiming.snoozeDeadline(for: event, respondedAt: respondedAt, interval: snoozeInterval)
  }
}
