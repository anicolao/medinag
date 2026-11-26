import XCTest

/// A real OS registration/replace/relaunch/cancel smoke test, not proof of sound.
/// No injected state, shortened timer, Firebase substitute, or fake alarm callbacks.
final class PrototypeUITests: XCTestCase {
  @MainActor
  func testSystemCountdownStopPresentation() throws {
    guard ProcessInfo.processInfo.environment["MEDINAG_SYSTEM_STOP_DIAGNOSTIC"] == "1" else {
      throw XCTSkip("Opt-in system-control diagnostic: the Simulator did not expose the countdown Stop. Not covered by the in-app intent smoke test.")
    }
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launch()
    XCTAssertTrue(app.buttons["set-test-alarm"].waitForExistence(timeout: 2))
    app.buttons["set-test-alarm"].tap()
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    let allow = springboard.alerts.buttons["Allow"]
    if allow.waitForExistence(timeout: 2) { allow.tap() }
    XCTAssertTrue(app.buttons["stop-and-respond"].waitForExistence(timeout: 2))
    XCUIDevice.shared.press(.home)
    print("SYSTEM_STOP_HIERARCHY_BEGIN\n\(springboard.debugDescription)\nSYSTEM_STOP_HIERARCHY_END")
    let stop = springboard.buttons["Stop"]
    XCTAssertTrue(stop.waitForExistence(timeout: 2), "System Stop control not exposed; inspect hierarchy, do not substitute the in-app action.")
    stop.tap()
    XCTAssertTrue(app.buttons["response-yes-i-did"].waitForExistence(timeout: 2))
    XCTAssertFalse(app.staticTexts["alarm-error"].exists)
    app.buttons["response-yes-i-did"].tap()
    XCTAssertTrue(app.staticTexts["No active test alarm"].waitForExistence(timeout: 2))
  }

  @MainActor
  func testStopIntentProtectsResponseAndBothChoices() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launch()
    XCTAssertTrue(app.buttons["set-test-alarm"].waitForExistence(timeout: 2))
    app.buttons["set-test-alarm"].tap()
    let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
    if allow.waitForExistence(timeout: 2) { allow.tap() }
    XCTAssertTrue(app.buttons["stop-and-respond"].waitForExistence(timeout: 2))
    // A real public in-app App Intent button using the same Stop intent; this
    // checks the handler, NOT the OS alarm screen's Stop or locked presentation.
    app.buttons["stop-and-respond"].tap()
    XCTAssertTrue(app.buttons["response-yes-i-did"].waitForExistence(timeout: 2))
    XCTAssertTrue(app.buttons["response-yes-i-will"].exists)
    XCTAssertFalse(app.staticTexts["alarm-error"].exists)
    app.terminate()
    app.launch()
    XCTAssertTrue(app.buttons["response-yes-i-will"].waitForExistence(timeout: 2))
    app.buttons["response-yes-i-will"].tap()
    XCTAssertTrue(app.buttons["stop-and-respond"].waitForExistence(timeout: 2))
    XCTAssertFalse(app.staticTexts["alarm-error"].exists)
    app.buttons["stop-and-respond"].tap()
    XCTAssertTrue(app.buttons["response-yes-i-did"].waitForExistence(timeout: 2))
    app.buttons["response-yes-i-did"].tap()
    XCTAssertTrue(app.staticTexts["No active test alarm"].waitForExistence(timeout: 2))
    app.terminate()
    app.launch()
    XCTAssertTrue(app.staticTexts["No active test alarm"].waitForExistence(timeout: 2))
    XCTAssertFalse(app.buttons["response-yes-i-did"].exists)
  }

  @MainActor
  func testRegisterReplaceRestoreAndCancel() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launch()
    XCTAssertTrue(app.buttons["set-test-alarm"].waitForExistence(timeout: 2))
    addUIInterruptionMonitor(withDescription: "Alarm permission") { alert in
      let allow = alert.buttons["Allow"]
      if allow.exists { allow.tap(); return true }
      return false
    }
    app.buttons["set-test-alarm"].tap()
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    let allow = springboard.alerts.buttons["Allow"]
    if allow.waitForExistence(timeout: 2) { allow.tap() }
    XCTAssertTrue(app.buttons["cancel-test-alarm"].waitForExistence(timeout: 2))
    XCTAssertEqual(app.staticTexts["alarm-registration"].label, "Alarm registered with iOS")
    XCTAssertFalse(app.staticTexts["alarm-error"].exists)
    app.buttons["set-test-alarm"].tap()
    let replacementFinished = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "enabled == true"), object: app.buttons["set-test-alarm"])
    wait(for: [replacementFinished], timeout: 2)
    XCTAssertTrue(app.buttons["cancel-test-alarm"].waitForExistence(timeout: 2))
    XCTAssertFalse(app.staticTexts["alarm-error"].exists)
    app.terminate()
    app.launch()
    XCTAssertTrue(app.buttons["cancel-test-alarm"].waitForExistence(timeout: 2))
    app.buttons["cancel-test-alarm"].tap()
    XCTAssertTrue(app.staticTexts["No active test alarm"].waitForExistence(timeout: 2))
  }
}
