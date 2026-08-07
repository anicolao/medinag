import XCTest

final class RespondToDoseUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
  }

  func testSteveSnoozesThenCompletesScheduledDose() throws {
    let app = XCUIApplication()
    app.launchArguments += [
      "-e2e",
      "-e2e-fixture",
      "scheduled-dose-pending",
      "-AppleLanguages", "(en)",
      "-AppleLocale", "en_CA",
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryM",
      "-NSTreatUnknownArgumentsAsOpen", "NO",
    ]
    app.launchEnvironment["TZ"] = "America/Toronto"
    let tester = TestStepHelper(
      testCase: self,
      application: app,
      storyID: "004-ios-respond-to-dose"
    )
    tester.setMetadata(
      title: "Steve responds to a scheduled dose",
      narrative:
        "As Steve, I want to snooze and then complete a medication reminder so Lori can see an accurate response."
    )

    app.launch()

    try tester.step(
      "pending-dose",
      description: "Steve sees the pending morning dose and both clear response choices",
      verifications: [
        .exists(app.otherElements["today-screen"], "The iOS Today screen is ready"),
        .exists(app.staticTexts["next-dose-name"], "The medication label is visible"),
        .exists(app.buttons["yes-i-will"], "The snooze response is available"),
        .exists(app.buttons["yes-i-did"], "The completion response is available"),
      ]
    )

    app.buttons["yes-i-will"].tap()

    try tester.step(
      "dose-snoozed",
      description: "Steve chooses Yes, I will and sees one scheduled repeat",
      verifications: [
        .labelContains(app.staticTexts["snooze-count"], "1", "The snooze count increments"),
        .labelContains(
          app.staticTexts["action-notice"], "10 minutes", "The repeat interval is confirmed"),
      ]
    )

    app.buttons["yes-i-did"].tap()

    try tester.step(
      "dose-completed",
      description: "Steve chooses Yes, I did and further nags are cancelled",
      verifications: [
        .labelContains(
          app.otherElements["event-morning-dose"], "Completed", "The dose is completed"),
        .labelContains(
          app.staticTexts["action-notice"], "cancelled", "The app confirms cancellation"),
      ]
    )

    try tester.generateDocs()
  }
}
