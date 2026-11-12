import Foundation

public struct MedicationSchedule: Identifiable, Codable, Equatable, Sendable {
  public let id: String
  public let medicationName: String
  public let scheduledTime: String
  public let daysOfWeek: [Int]
  public let active: Bool

  public init(
    id: String,
    medicationName: String,
    scheduledTime: String,
    daysOfWeek: [Int],
    active: Bool
  ) {
    self.id = id
    self.medicationName = medicationName
    self.scheduledTime = scheduledTime
    self.daysOfWeek = daysOfWeek
    self.active = active
  }
}

public enum MedicationEventStatus: String, Codable, Sendable {
  case pending
  case snoozed
  case completed
}

public struct MedicationEvent: Identifiable, Codable, Equatable, Sendable {
  public let id: String
  public let scheduleID: String
  public let medicationName: String
  public let occurrenceDate: String
  public let scheduledLocalTime: String
  public let timeZone: String
  public let scheduledTime: Date
  public var status: MedicationEventStatus
  public var snoozeCount: Int
  public var lastSnoozedAt: Date?
  public var completedAt: Date?
  // Local policy travels with the real occurrence/cache/Watch payload, not as
  // a fake event. Optional fields preserve decoding of previously saved data.
  public var snoozeIntervalSeconds: TimeInterval?
  public var repeatIntervalSeconds: TimeInterval?
  public var snoozedUntil: Date?

  public init(
    id: String,
    scheduleID: String,
    medicationName: String,
    occurrenceDate: String = "",
    scheduledLocalTime: String = "",
    timeZone: String = "UTC",
    scheduledTime: Date,
    status: MedicationEventStatus,
    snoozeCount: Int,
    lastSnoozedAt: Date? = nil,
    completedAt: Date? = nil
  ) {
    self.id = id
    self.scheduleID = scheduleID
    self.medicationName = medicationName
    self.occurrenceDate = occurrenceDate
    self.scheduledLocalTime = scheduledLocalTime
    self.timeZone = timeZone
    self.scheduledTime = scheduledTime
    self.status = status
    self.snoozeCount = snoozeCount
    self.lastSnoozedAt = lastSnoozedAt
    self.completedAt = completedAt
  }
}

public enum DoseResponse: String, Codable, Sendable {
  case yesIWill
  case yesIDid
}

public extension MedicationEvent {
  func hasSameOccurrence(as other: MedicationEvent) -> Bool {
    id == other.id && scheduleID == other.scheduleID
      && medicationName == other.medicationName && scheduledTime == other.scheduledTime
      && timeZone == other.timeZone
  }

  /// A later transport timestamp is not evidence of a later patient response.
  /// Preserve terminal completion and monotonic snooze progress for the same
  /// occurrence, including after an acknowledgement removed an outbox entry.
  func preservingResponseProgress(from previous: MedicationEvent) -> MedicationEvent {
    guard hasSameOccurrence(as: previous), status != .completed,
      previous.status == .completed || previous.snoozeCount > snoozeCount
        || (previous.status == .snoozed && status == .pending && previous.snoozeCount == snoozeCount)
    else { return self }
    var merged = self
    merged.status = previous.status
    merged.snoozeCount = previous.snoozeCount
    merged.lastSnoozedAt = previous.lastSnoozedAt
    merged.completedAt = previous.completedAt
    merged.snoozedUntil = previous.snoozedUntil
    return merged
  }

  /// Status plus the monotonic snooze count identify a patient-response
  /// version. Do not compare fractional Date values after JSON/Firestore
  /// round-trips: their sub-microsecond representations can differ.
  func hasSameResponseVersion(as other: MedicationEvent) -> Bool {
    hasSameOccurrence(as: other) && status == other.status && snoozeCount == other.snoozeCount
  }
}
