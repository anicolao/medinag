import FirebaseCore
import Foundation

enum FirebaseBootstrap {
  @discardableResult
  static func configure() -> Bool {
    if FirebaseApp.app() != nil {
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
