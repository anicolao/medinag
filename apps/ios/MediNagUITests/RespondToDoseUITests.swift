import XCTest

final class RespondToDoseUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
  }

  func testFirstReminderSchedulesRepeat() throws {
    let app = makeApplication(fixture: "scheduled-dose-first-reminder")
    let tester = makeTester(application: app)
    app.launch()

    try tester.step(
      "first-reminder",
      description: "The first medication reminder arrives exactly at 8:00 AM",
      verifications: firstReminderVerifications(app)
    )

    app.buttons["reminder-yes-i-will"].tap()

    try tester.step(
      "dose-snoozed",
      description: "Steve chooses Yes, I will and the dose is snoozed for 10 minutes",
      verifications: snoozedVerifications(app)
    )
  }

  func testRepeatReminderCompletesDose() throws {
    let app = makeApplication(fixture: "scheduled-dose-repeat-due")
    let tester = makeTester(application: app, startingStepIndex: 2)
    tester.documentPriorStep(
      "first-reminder",
      index: 0,
      description: "The first medication reminder arrives exactly at 8:00 AM",
      verifications: firstReminderSpecs
    )
    tester.documentPriorStep(
      "dose-snoozed",
      index: 1,
      description: "Steve chooses Yes, I will and the dose is snoozed for 10 minutes",
      verifications: snoozedSpecs
    )
    app.launch()

    try tester.step(
      "repeat-reminder",
      description: "At 8:10 AM the expired snooze presents the next reminder",
      verifications: [
        .exists(app.otherElements["dose-reminder-alert"], "The repeat alert is visible"),
        .labelContains(app.staticTexts["reminder-sequence"], "REMINDER 2", "This is reminder 2"),
        .labelContains(app.staticTexts["reminder-time"], "8:10", "The repeat arrives at 8:10 AM"),
        .exists(app.buttons["reminder-yes-i-will"], "Yes, I will is offered after the repeat"),
        .exists(app.buttons["reminder-yes-i-did"], "Yes, I did is offered after the repeat"),
        .sameSize(
          app.buttons["reminder-yes-i-will"],
          app.buttons["reminder-yes-i-did"],
          "Neither response has greater visual weight"
        ),
      ]
    )

    app.buttons["reminder-yes-i-did"].tap()

    try tester.step(
      "dose-completed",
      description: "Steve chooses Yes, I did and further nags are cancelled",
      verifications: [
        .labelContains(
          app.staticTexts["event-morning-dose-status"],
          "Completed",
          "The dose is completed"),
        .labelContains(
          app.staticTexts["action-notice"], "cancelled", "The app confirms cancellation"),
      ]
    )

    try tester.generateDocs()
  }

  private func makeApplication(fixture: String) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += [
      "-e2e",
      "-e2e-fixture",
      fixture,
      "-AppleLanguages", "(en)",
      "-AppleLocale", "en_CA",
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryM",
      "-NSTreatUnknownArgumentsAsOpen", "NO",
    ]
    app.launchEnvironment["TZ"] = "America/Toronto"
    return app
  }

  private func makeTester(
    application: XCUIApplication,
    startingStepIndex: Int = 0
  ) -> TestStepHelper {
    let tester = TestStepHelper(
      testCase: self,
      application: application,
      storyID: "004-ios-respond-to-dose",
      startingStepIndex: startingStepIndex
    )
    tester.setMetadata(
      title: "Steve responds to a scheduled dose",
      narrative:
        "As Steve, I want to snooze and then complete a medication reminder so Lori can see an accurate response."
    )
    return tester
  }

  private func firstReminderVerifications(_ app: XCUIApplication) -> [StepVerification] {
    [
      .exists(app.otherElements["dose-reminder-alert"], "The first alert is visible"),
      .labelContains(app.staticTexts["reminder-sequence"], "FIRST", "This is the first reminder"),
      .labelContains(app.staticTexts["reminder-time"], "8:00", "The first reminder arrives at 8:00 AM"),
      .exists(app.buttons["reminder-yes-i-will"], "The snooze response is available"),
      .exists(app.buttons["reminder-yes-i-did"], "The completion response is available"),
      .sameSize(
        app.buttons["reminder-yes-i-will"],
        app.buttons["reminder-yes-i-did"],
        "Neither response has greater visual weight"
      ),
    ]
  }

  private func snoozedVerifications(_ app: XCUIApplication) -> [StepVerification] {
    [
      .labelContains(app.staticTexts["snooze-count"], "1", "The snooze count increments"),
      .labelContains(
        app.staticTexts["action-notice"], "10 minutes", "The configured repeat interval is confirmed"),
      .labelContains(
        app.staticTexts["event-morning-dose-status"], "Snoozed", "The dose remains unfinished"),
    ]
  }

  private var firstReminderSpecs: [String] {
    firstReminderVerifications(XCUIApplication()).map(\.spec)
  }

  private var snoozedSpecs: [String] {
    snoozedVerifications(XCUIApplication()).map(\.spec)
  }
}
