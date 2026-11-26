import XCTest

/// A real OS registration/replace/relaunch/cancel smoke test, not proof of sound.
/// No injected state, shortened timer, Firebase substitute, or fake alarm callbacks.
final class PrototypeUITests: XCTestCase {
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
