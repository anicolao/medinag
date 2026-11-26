import AppIntents
import Foundation

/// AlarmKit stops its alarm itself. Our work first replaces that protection;
/// deferred foreground execution asks iOS to open the app AFTER perform runs.
struct StopAndRespondIntent: LiveActivityIntent {
  static let title: LocalizedStringResource = "Respond to MediNag alarm"
  static var supportedModes: IntentModes { [.foreground(.deferred)] }
  static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }

  @Parameter(title: "Alarm identifier") var alarmIdentifier: String

  init() {}
  init(alarmID: UUID) { alarmIdentifier = alarmID.uuidString }

  @MainActor
  func perform() async throws -> some IntentResult {
    guard let id = UUID(uuidString: alarmIdentifier) else {
      throw PrototypeModel.Failure("The Stop action has no valid alarm identifier.")
    }
    await PrototypeModel.shared.stopped(alarmID: id)
    // No openAppWhenRun/immediate foreground: those could gate follow-up
    // registration on unlocking or presenting a SwiftUI scene first.
    return .result()
  }
}
