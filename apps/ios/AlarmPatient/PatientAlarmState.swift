import Foundation
import MediNagCore

struct PatientAlarmState: Codable, Sendable {
  struct Context: Codable, Sendable {
    let patientID: String
    var plan: PublishedPlan
    let enrolledAt: Date
  }
  struct Binding: Codable, Sendable, Identifiable {
    let id: UUID
    let eventID: String
    let deadline: Date
    let followup: Bool
    let snoozeSeconds: TimeInterval
    var verified = false
    var configurationVersion: Int? = nil
  }
  struct Evidence: Codable, Sendable, Identifiable {
    let id: String
    let kind: String
    let eventID: String
    let observedAt: Date
    let detail: String
  }
  var context: Context?
  var events: [MedicationEvent] = []
  var bindings: [Binding] = []
  var responses: [LocalDoseResponse] = []
  var evidence: [Evidence] = []
  var responseEventID: String?
  var lastFailure: String?
  var deviceID = UUID().uuidString
  var verifiedAlarmIDs: [UUID] = []
  var verificationObservedAt: Date?
  var verifiedThrough: Date?
  var migrated = false
  var retiredBefore: Date?

  var eligibleEvents: [MedicationEvent] {
    guard let context else { return [] }
    return events.filter { $0.scheduledTime >= max(context.enrolledAt, retiredBefore ?? .distantPast) }
  }

  func latestDue(at now: Date) -> MedicationEvent? {
    // Find the newest occurrence BEFORE filtering completion. Completing it
    // must not uncover an older unanswered medication.
    AlarmKitPolicy.latestDue(in: eligibleEvents, at: now)
  }

  func nextDose(at now: Date) -> MedicationEvent? {
    eligibleEvents.filter { $0.scheduledTime > now && $0.status != .completed }
      .min { $0.scheduledTime < $1.scheduledTime }
  }

  func successor(of event: MedicationEvent) -> Date? {
    eligibleEvents.filter { $0.scheduledTime > event.scheduledTime }.map(\.scheduledTime).min()
  }

  static func gridDeadline(origin: Date, now: Date, interval: TimeInterval) -> Date {
    AlarmKitPolicy.gridDeadline(origin: origin, now: now, interval: interval)
  }
}

enum PatientAlarmDisk {
  static func url() throws -> URL {
    try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
      appropriateFor: nil, create: true).appendingPathComponent("patient-alarmkit.json")
  }
  static func load() throws -> PatientAlarmState {
    let file = try url()
    guard FileManager.default.fileExists(atPath: file.path) else { return PatientAlarmState() }
    return try JSONDecoder().decode(PatientAlarmState.self, from: Data(contentsOf: file))
  }
  static func save(_ state: PatientAlarmState) throws {
    try JSONEncoder().encode(state).write(to: url(),
      options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
  }
}
