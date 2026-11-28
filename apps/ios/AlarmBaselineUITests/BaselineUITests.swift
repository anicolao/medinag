import XCTest

/// Real SDK setup/restore/cancel smoke check, not audible-delivery validation.
final class BaselineUITests: XCTestCase {
  @MainActor
  func testSingleOrdinaryAlarmRegistration() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launch()
    app.buttons["prepare-baseline"].tap()
    let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
    if allow.waitForExistence(timeout: 2) { allow.tap() }
    XCTAssertTrue(app.staticTexts["baseline-prepared"].waitForExistence(timeout: 2))
    app.buttons["arm-baseline"].tap()
    let inventory = app.staticTexts["baseline-inventory"]
    let registered = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label == %@", "One alarm registered with iOS"), object: inventory)
    wait(for: [registered], timeout: 2)
    app.terminate()
    app.launch()
    let restored = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label == %@", "One alarm registered with iOS"), object: inventory)
    wait(for: [restored], timeout: 2)
    app.buttons["cancel-baseline"].tap()
    let absent = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label == %@", "No baseline alarm in OS inventory"), object: inventory)
    wait(for: [absent], timeout: 2)
  }
}
