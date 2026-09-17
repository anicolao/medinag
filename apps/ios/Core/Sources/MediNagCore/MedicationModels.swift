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
  public let scheduledTime: Date
  public var status: MedicationEventStatus
  public var snoozeCount: Int
  public var lastSnoozedAt: Date?
  public var completedAt: Date?

  public init(
    id: String,
    scheduleID: String,
    medicationName: String,
    scheduledTime: Date,
    status: MedicationEventStatus,
    snoozeCount: Int,
    lastSnoozedAt: Date? = nil,
    completedAt: Date? = nil
  ) {
    self.id = id
    self.scheduleID = scheduleID
    self.medicationName = medicationName
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
