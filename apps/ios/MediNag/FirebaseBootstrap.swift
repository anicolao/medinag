import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import Foundation

enum FirebaseBootstrap {
  @discardableResult
  static func configure() -> Bool {
    if FirebaseApp.app() != nil {
      return true
    }
    if let emulator = EmulatorConfiguration.resolve(
      arguments: ProcessInfo.processInfo.arguments
    ) {
      guard let bundleID = Bundle.main.bundleIdentifier else { return false }
      let options = FirebaseOptions(
        googleAppID: emulator.appID,
        gcmSenderID: emulator.messagingSenderID
      )
      options.apiKey = emulator.apiKey
      options.projectID = emulator.projectID
      options.bundleID = bundleID
      FirebaseApp.configure(options: options)
      Auth.auth().useEmulator(withHost: emulator.host, port: emulator.authPort)
      let database = Firestore.firestore()
      let settings = database.settings
      settings.host = "\(emulator.host):\(emulator.firestorePort)"
      settings.cacheSettings = MemoryCacheSettings()
      settings.isSSLEnabled = false
      database.settings = settings
      return true
    }
    guard
      let path = Bundle.main.path(
        forResource: "GoogleService-Info",
        ofType: "plist"
      ),
      let options = FirebaseOptions(contentsOfFile: path)
    else {
      return false
    }
    FirebaseApp.configure(options: options)
    return true
  }
}

private struct EmulatorConfiguration: Codable {
  let projectID: String
  let apiKey: String
  let appID: String
  let messagingSenderID: String
  let host: String
  let authPort: Int
  let firestorePort: Int

  private static let defaultsKey = "medinag.e2e.firebase-emulator-configuration"

  static func resolve(arguments: [String]) -> EmulatorConfiguration? {
    if let configuration = EmulatorConfiguration(arguments: arguments) {
      #if E2E
        if let data = try? JSONEncoder().encode(configuration) {
          UserDefaults.standard.set(data, forKey: defaultsKey)
        }
      #endif
      return configuration
    }
    #if E2E
      guard
        let data = UserDefaults.standard.data(forKey: defaultsKey),
        let configuration = try? JSONDecoder().decode(
          EmulatorConfiguration.self,
          from: data
        )
      else {
        return nil
      }
      return configuration
    #else
      return nil
    #endif
  }

  private init?(arguments: [String]) {
    guard
      let projectID = arguments.launchValue(after: "-firebase-emulator-project-id"),
      let apiKey = arguments.launchValue(after: "-firebase-emulator-api-key"),
      let appID = arguments.launchValue(after: "-firebase-emulator-app-id"),
      let messagingSenderID = arguments.launchValue(
        after: "-firebase-emulator-messaging-sender-id"
      ),
      let host = arguments.launchValue(after: "-firebase-emulator-host"),
      let authPortValue = arguments.launchValue(after: "-firebase-auth-emulator-port"),
      let authPort = Int(authPortValue),
      let firestorePortValue = arguments.launchValue(
        after: "-firebase-firestore-emulator-port"
      ),
      let firestorePort = Int(firestorePortValue)
    else {
      return nil
    }
    self.projectID = projectID
    self.apiKey = apiKey
    self.appID = appID
    self.messagingSenderID = messagingSenderID
    self.host = host
    self.authPort = authPort
    self.firestorePort = firestorePort
  }
}

private extension Array where Element == String {
  func launchValue(after argument: String) -> String? {
    guard let index = firstIndex(of: argument) else { return nil }
    let valueIndex = self.index(after: index)
    guard indices.contains(valueIndex) else { return nil }
    return self[valueIndex]
  }
}
