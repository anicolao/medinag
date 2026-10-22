import XCTest

@MainActor
final class WatchPairingUITests: XCTestCase {
  override func setUp() { continueAfterFailure = false }

  func testPhoneBeforeSignIn() throws {
    let app = try ConnectedEnvironment().makeApplication()
    app.launch()
    let tester = TestStepHelper(testCase: self, application: app, storyID: "006-watch-companion")
    try tester.step("phone-sign-in", description: "The patient sets up the paired iPhone first",
                    verifications: [.exists(app.buttons["patient-google-sign-in"], "Google sign-in is available on iPhone")])
  }

  func testFollowScheduleOnPhone() throws {
    let environment = try ConnectedEnvironment()
    let app = environment.makeApplication()
    app.launch()
    XCTAssertTrue(app.buttons["patient-google-sign-in"].waitForExistence(timeout: 2))
    app.buttons["patient-google-sign-in"].tap()
    XCTAssertTrue(app.buttons["continue-after-authentication"].waitForExistence(timeout: 2))
    app.buttons["continue-after-authentication"].tap()
    let plan = app.buttons["schedule-option-\(environment.administratorID)"]
    XCTAssertTrue(plan.waitForExistence(timeout: 2))
    plan.tap()
    app.buttons["follow-schedule"].tap()
    XCTAssertTrue(app.buttons["continue-after-following"].waitForExistence(timeout: 2))
    app.buttons["continue-after-following"].tap()
    XCTAssertTrue(app.buttons["allow-notifications"].waitForExistence(timeout: 2))
    app.buttons["allow-notifications"].tap()
    let permission = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
    XCTAssertTrue(permission.waitForExistence(timeout: 2))
    permission.buttons["Allow"].tap()
    let tester = TestStepHelper(testCase: self, application: app, storyID: "006-watch-companion", startingStepIndex: 1)
    try tester.step("phone-following", description: "The iPhone receives the published dose and registers its system alarm",
                    verifications: [
                      .labelContains(app.staticTexts["next-dose-name"], environment.medicationName, "The real Firestore dose is visible on iPhone"),
                      .labelContains(app.descendants(matching: .any).matching(identifier: "pending-reminder-count").firstMatch,
                                     "6 of 6", "iOS confirms the scheduled medication alarms"),
                    ], screenshotElement: app.otherElements["reminder-diagnostics"])
  }
}
