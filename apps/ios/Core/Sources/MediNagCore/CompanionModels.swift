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
  public let repeatMinutes: Int?
  public let maximumReminderCount: Int
  public let ready: Bool
  public let readinessMessage: String
  public let logicalDate: Date
  public let realDate: Date
  public let clockScale: Double
  /// Absent in older payloads. Only an authoritative unlink/sign-out may clear
  /// a ready Watch cache; a phone restart/network failure must not erase it.
  public let scheduleCleared: Bool?

  public init(patientID: String?, administratorID: String?, administratorName: String,
              planName: String, events: [MedicationEvent], snoozeMinutes: Int,
              maximumReminderCount: Int, ready: Bool, readinessMessage: String,
              logicalDate: Date, realDate: Date, clockScale: Double = 1,
              scheduleCleared: Bool = false, repeatMinutes: Int = 3) {
    self.patientID = patientID
    self.administratorID = administratorID
    self.administratorName = administratorName
    self.planName = planName
    self.events = events
    self.snoozeMinutes = snoozeMinutes
    self.repeatMinutes = repeatMinutes
    self.maximumReminderCount = maximumReminderCount
    self.ready = ready
    self.readinessMessage = readinessMessage
    self.logicalDate = logicalDate
    self.realDate = realDate
    self.clockScale = clockScale > 0 ? clockScale : 1
    self.scheduleCleared = scheduleCleared
  }

  public func nextReminder(for event: MedicationEvent) -> Date {
    AlertTiming.reminder(for: event, snoozeInterval: Double(snoozeMinutes * 60))
  }

  public func canRespond(to event: MedicationEvent, at date: Date = Date()) -> Bool {
    let now = logicalDate.addingTimeInterval(date.timeIntervalSince(realDate) / clockScale)
    return ready && AlertTiming.canComplete(event, among: events, at: now,
      snoozeInterval: Double(snoozeMinutes * 60))
  }

  public var nextEvent: MedicationEvent? {
    nextEvent(at: Date())
  }

  public func nextEvent(at date: Date) -> MedicationEvent? {
    let now = logicalDate.addingTimeInterval(date.timeIntervalSince(realDate) / clockScale)
    return DoseWindow.nextEvent(in: events, at: now, snoozeInterval: Double(snoozeMinutes * 60))
  }

  public func canReplace(_ cached: CompanionSnapshot?) -> Bool {
    guard let cached else { return true }
    guard realDate >= cached.realDate else { return false }
    return ready || scheduleCleared == true || !cached.ready
  }

  public func replacingEvents(_ events: [MedicationEvent]) -> CompanionSnapshot {
    CompanionSnapshot(patientID: patientID, administratorID: administratorID,
      administratorName: administratorName, planName: planName, events: events,
      snoozeMinutes: snoozeMinutes, maximumReminderCount: maximumReminderCount,
      ready: ready, readinessMessage: readinessMessage, logicalDate: logicalDate,
      realDate: realDate, clockScale: clockScale, scheduleCleared: scheduleCleared == true,
      repeatMinutes: repeatMinutes ?? 3)
  }

  public func preservingResponseProgress(from cached: CompanionSnapshot?) -> CompanionSnapshot {
    guard let cached, patientID == cached.patientID, administratorID == cached.administratorID,
      scheduleCleared != true else { return self }
    return replacingEvents(events.map { event in
      cached.events.first(where: { $0.id == event.id }).map { event.preservingResponseProgress(from: $0) } ?? event
    })
  }
}

public struct CompanionCommand: Codable, Sendable {
  public let id: String?
  public let patientID: String?
  public let administratorID: String?
  public let event: MedicationEvent?
  public let response: DoseResponse?
  public let respondedAt: Date?

  public init(snapshot: CompanionSnapshot? = nil, event: MedicationEvent? = nil,
              response: DoseResponse? = nil) {
    id = UUID().uuidString
    patientID = snapshot?.patientID
    administratorID = snapshot?.administratorID
    self.event = event
    self.response = response
    respondedAt = response == nil ? nil : snapshot.map {
      $0.logicalDate.addingTimeInterval(Date().timeIntervalSince($0.realDate) / $0.clockScale)
    }
  }

  public var identifier: String {
    id ?? "legacy.\(patientID ?? "").\(administratorID ?? "").\(event?.id ?? "").\(event?.snoozeCount ?? -1).\(response?.rawValue ?? "refresh")"
  }

  public func remainsPending(in snapshot: CompanionSnapshot, at date: Date) -> Bool {
    guard patientID == snapshot.patientID, administratorID == snapshot.administratorID,
      let expected = event, let current = snapshot.events.first(where: { $0.id == expected.id }) else { return false }
    let now = snapshot.logicalDate.addingTimeInterval(date.timeIntervalSince(snapshot.realDate) / snapshot.clockScale)
    return current.hasSameOccurrence(as: expected)
      && DoseWindow.isActive(current, among: snapshot.events, at: now)
      && (response == .yesIDid || current.snoozeCount <= expected.snoozeCount)
  }
}

public struct CompanionReply: Codable, Sendable {
  public let snapshot: CompanionSnapshot
  public let accepted: Bool
  public let message: String
  public let commandID: String?
  public let retryable: Bool?

  public init(snapshot: CompanionSnapshot, accepted: Bool, message: String,
              commandID: String? = nil, retryable: Bool = false) {
    self.snapshot = snapshot
    self.accepted = accepted
    self.message = message
    self.commandID = commandID
    self.retryable = retryable
  }

  public func acknowledging(_ command: CompanionCommand) -> CompanionReply {
    CompanionReply(snapshot: snapshot, accepted: accepted, message: message,
      commandID: command.identifier, retryable: retryable == true)
  }

  public func resolves(_ command: CompanionCommand) -> Bool {
    guard commandID == command.identifier else { return false }
    guard accepted else { return retryable != true }
    // An ACK for local receipt is not proof that the returned schedule reflects
    // the tap. Keep the durable overlay until a matching/newer response arrives.
    guard let expected = command.event, let response = command.response,
      let current = snapshot.events.first(where: { $0.hasSameOccurrence(as: expected) }) else { return false }
    return current.status == .completed
      || (response == .yesIWill && current.status == .snoozed && current.snoozeCount > expected.snoozeCount)
  }
}

public enum DoseMutationError: LocalizedError {
  case staleEvent
  public var errorDescription: String? {
    "This dose changed on another device. Refresh and check its current status before responding again."
  }
}
