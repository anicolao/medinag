import Foundation

/// Only real patient/event data crosses the paired-device connection. No Auth
/// tokens or Firebase credentials are transferred to the Watch.
public struct CompanionSnapshot: Codable, Sendable {
  public let patientID: String?
  public let administratorID: String?
  public let administratorName: String
  public let planName: String
  public let events: [MedicationEvent]
  public let snoozeMinutes: Int
  public let maximumReminderCount: Int
  public let ready: Bool
  public let readinessMessage: String
  public let logicalDate: Date
  public let realDate: Date
  public let clockScale: Double

  public init(patientID: String?, administratorID: String?, administratorName: String,
              planName: String, events: [MedicationEvent], snoozeMinutes: Int,
              maximumReminderCount: Int, ready: Bool, readinessMessage: String,
              logicalDate: Date, realDate: Date, clockScale: Double = 1) {
    self.patientID = patientID
    self.administratorID = administratorID
    self.administratorName = administratorName
    self.planName = planName
    self.events = events
    self.snoozeMinutes = snoozeMinutes
    self.maximumReminderCount = maximumReminderCount
    self.ready = ready
    self.readinessMessage = readinessMessage
    self.logicalDate = logicalDate
    self.realDate = realDate
    self.clockScale = clockScale > 0 ? clockScale : 1
  }

  public func nextReminder(for event: MedicationEvent) -> Date {
    event.status == .snoozed
      ? (event.lastSnoozedAt ?? event.scheduledTime).addingTimeInterval(Double(snoozeMinutes * 60))
      : event.scheduledTime
  }

  public func canRespond(to event: MedicationEvent, at date: Date = Date()) -> Bool {
    let now = logicalDate.addingTimeInterval(date.timeIntervalSince(realDate) / clockScale)
    return ready && event.status != .completed && nextReminder(for: event).timeIntervalSince(now) < 15 * 60
  }

  public var nextEvent: MedicationEvent? {
    events.filter { $0.status != .completed }.min {
      nextReminder(for: $0) < nextReminder(for: $1)
    }
  }
}

public struct CompanionCommand: Codable, Sendable {
  public let patientID: String?
  public let administratorID: String?
  public let event: MedicationEvent?
  public let response: DoseResponse?

  public init(snapshot: CompanionSnapshot? = nil, event: MedicationEvent? = nil,
              response: DoseResponse? = nil) {
    patientID = snapshot?.patientID
    administratorID = snapshot?.administratorID
    self.event = event
    self.response = response
  }
}

public struct CompanionReply: Codable, Sendable {
  public let snapshot: CompanionSnapshot
  public let accepted: Bool
  public let message: String

  public init(snapshot: CompanionSnapshot, accepted: Bool, message: String) {
    self.snapshot = snapshot
    self.accepted = accepted
    self.message = message
  }
}

public enum DoseMutationError: LocalizedError {
  case staleEvent
  public var errorDescription: String? {
    "This dose changed on another device. Refresh and check its current status before responding again."
  }
}
