import AppIntents
import Foundation

extension Notification.Name {
  static let patientAlarmChanged = Notification.Name("medinag.patient-alarm-changed")
}

struct PatientStopIntent: LiveActivityIntent {
  static let title: LocalizedStringResource = "Respond to medication reminder"
  static var supportedModes: IntentModes { [.foreground(.deferred)] }
  static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }
  @Parameter(title: "Alarm identifier") var identifier: String
  init() {}
  init(alarmID: UUID) { identifier = alarmID.uuidString }
  func perform() async throws -> some IntentResult {
    if let id = UUID(uuidString: identifier) { _ = await PatientAlarmEngine.shared.run(.stop(id)) }
    await MainActor.run {
      NotificationCenter.default.post(name: .patientAlarmChanged, object: nil)
      PatientSession.shared.scheduleFlush()
    }
    return .result()
  }
}

struct PatientSnoozeIntent: LiveActivityIntent {
  static let title: LocalizedStringResource = "Snooze medication reminder"
  static var supportedModes: IntentModes { [.background] }
  static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }
  @Parameter(title: "Alarm identifier") var identifier: String
  init() {}
  init(alarmID: UUID) { identifier = alarmID.uuidString }
  func perform() async throws -> some IntentResult {
    if let id = UUID(uuidString: identifier) { _ = await PatientAlarmEngine.shared.run(.snooze(id)) }
    await MainActor.run {
      NotificationCenter.default.post(name: .patientAlarmChanged, object: nil)
      PatientSession.shared.scheduleFlush()
    }
    return .result()
  }
}
