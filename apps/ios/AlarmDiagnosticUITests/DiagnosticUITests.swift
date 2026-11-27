import XCTest

/// Registration/persistence/cancellation only. Does NOT claim sound, system
/// Stop, or retry delivery: those are the explicit physical experiment.
final class DiagnosticUITests: XCTestCase {
  @MainActor
  func testRegisterThreeRealAlarmsRestoreAndCancel() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launch()
    app.buttons["finish-diagnostic-test"].tap()
    app.buttons["arm-diagnostic-alarms"].tap()
    let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
    if allow.waitForExistence(timeout: 2) { allow.tap() }
    let count = app.staticTexts["diagnostic-inventory"]
    XCTAssertTrue(count.waitForExistence(timeout: 2))
    XCTAssertEqual(count.label, "3 OS alarms registered")
    for index in 0...2 { XCTAssertTrue(app.staticTexts["diagnostic-deadline-\(index)"].exists) }
    app.terminate()
    app.launch()
    XCTAssertTrue(count.waitForExistence(timeout: 2))
    let restored = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "3 OS alarms registered"), object: count)
    wait(for: [restored], timeout: 2)
    app.buttons["finish-diagnostic-test"].tap()
    XCTAssertTrue(app.buttons["arm-diagnostic-alarms"].isEnabled)
    XCTAssertFalse(count.exists)
  }
}
