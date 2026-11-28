import XCTest

final class PatientConnectedUITests: XCTestCase {
  @MainActor
  func testRealScheduleEarlyCompletion() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    // The connected runner supplies only real emulator connection/auth inputs.
    // No plan, dose event, response, or fake notification is injected here.
    let environment = ProcessInfo.processInfo.environment
    guard let arguments = environment["MEDINAG_PATIENT_LAUNCH_ARGUMENTS"],
      let data = arguments.data(using: .utf8),
      let decoded = try JSONSerialization.jsonObject(with: data) as? [String] else {
      throw XCTSkip("Run through the real Firebase/web connected story runner.")
    }
    app.launchArguments = decoded
    app.launch()
    XCTAssertTrue(app.buttons["google-sign-in"].waitForExistence(timeout: 2))
    app.buttons["google-sign-in"].tap()
    let follow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "follow-plan-")).firstMatch
    XCTAssertTrue(follow.waitForExistence(timeout: 2))
    follow.tap()
    XCTAssertTrue(app.buttons["enable-alarms"].waitForExistence(timeout: 2))
    app.buttons["enable-alarms"].tap()
    let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
    XCTAssertTrue(allow.waitForExistence(timeout: 2))
    allow.tap()
    XCTAssertTrue(app.buttons["response-yes-i-did"].waitForExistence(timeout: 2))
    XCTAssertFalse(app.buttons["response-yes-i-will"].exists, "An early dose can only be completed, not snoozed.")
    app.buttons["response-yes-i-did"].tap()
    XCTAssertTrue(app.otherElements["next-dose-screen"].waitForExistence(timeout: 2))
    XCTAssertFalse(app.buttons["response-yes-i-did"].exists)
    app.terminate()
    app.launch()
    XCTAssertTrue(app.otherElements["next-dose-screen"].waitForExistence(timeout: 2))
  }
}
