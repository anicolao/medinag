import XCTest

@MainActor
final class RespondToDoseUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  func testConnectedSystemNotificationDoseLoop() throws {
    XCUIDevice.shared.orientation = .portrait
    let environment = try ConnectedEnvironment()
    let app = makeApplication(environment)
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    let tester = makeTester(application: app)
    app.launch()

    try tester.step(
      "subject-sign-in",
      description: "Steve signs in to the same Firebase household",
      verifications: [
        .exists(app.textFields["subject-email"], "The real Firebase Auth form is visible"),
        .exists(app.secureTextFields["subject-password"], "The password field is visible"),
        .exists(app.textFields["household-id"], "The household pairing field is visible"),
      ]
    )

    app.textFields["subject-email"].tap()
    app.textFields["subject-email"].typeText(environment.subjectEmail)
    app.secureTextFields["subject-password"].tap()
    app.secureTextFields["subject-password"].typeText(environment.subjectPassword)
    app.textFields["household-id"].tap()
    app.textFields["household-id"].typeText(environment.householdID)
    app.keyboards.buttons["Return"].tap()
    XCTAssertTrue(
      app.buttons["subject-sign-in"].isHittable,
      "The Connect button must be visible after entering the generated credentials"
    )
    app.buttons["subject-sign-in"].tap()

    let eventStatus = app.staticTexts.matching(
      NSPredicate(
        format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
        "event-",
        "-status"
      )
    ).firstMatch
    try tester.step(
      "firestore-event-received",
      description: "The iPhone receives Lori's schedule and event through Firestore",
      verifications: [
        .labelContains(
          app.staticTexts["next-dose-name"],
          environment.medicationName,
          "The medication label written by Lori appears from the snapshot listener"
        ),
        .labelContains(
          eventStatus,
          "Waiting for your response",
          "The real medication event is pending"
        ),
        .exists(app.buttons["allow-notifications"], "The app offers notification permission"),
      ]
    )

    app.buttons["allow-notifications"].tap()
    let permissionAlert = springboard.alerts.firstMatch
    try tester.step(
      "notification-permission",
      description: "iOS asks Steve to allow MediNag notifications",
      verifications: [
        .exists(permissionAlert, "The permission prompt is rendered by iOS"),
        .exists(permissionAlert.buttons["Allow"], "The system offers an Allow action"),
      ]
    )
    permissionAlert.buttons["Allow"].tap()

    try tester.step(
      "waiting-for-first-reminder",
      description: "MediNag is ready and waits for the scheduled notification",
      verifications: [
        .labelContains(
          app.staticTexts["notification-readiness"],
          "Reminders are ready",
          "Notification permission is ready"
        ),
        .labelContains(
          app.staticTexts["next-dose-name"],
          environment.medicationName,
          "The Firestore event remains visible while the app waits"
        ),
        .notExists(app.buttons["yes-i-will"], "No response is available before a notification"),
        .notExists(app.buttons["yes-i-did"], "No completion is available before a notification"),
      ]
    )

    XCUIDevice.shared.press(.home)
    let firstNotification = springboard.descendants(matching: .any)[
      "NotificationShortLookView"
    ]
    let firstNotificationTitle = springboard.staticTexts["Medication reminder"].firstMatch
    XCTAssertTrue(
      firstNotification.waitForExistence(timeout: TestStepHelper.conditionTimeout),
      "SpringBoard did not receive the notification built from the Firestore event"
    )
    app.terminate()
    try tester.step(
      "first-system-notification",
      description: "With MediNag terminated, iOS retains the scheduled notification",
      verifications: [
        .exists(firstNotificationTitle, "The first reminder is rendered by SpringBoard"),
      ],
      screenshotElement: firstNotification
    )

    firstNotification.tap()
    try tester.step(
      "first-reminder-response",
      description: "Tapping the notification cold-launches the response screen",
      verifications: reminderVerifications(
        app,
        sequence: "FIRST",
        time: environment.scheduledDisplayTime
      )
    )

    app.buttons["reminder-yes-i-will"].tap()
    try tester.step(
      "dose-snoozed-in-firestore",
      description: "Yes, I will writes the snoozed response back to Firestore",
      verifications: [
        .labelContains(app.staticTexts["snooze-count"], "1", "The snooze count increments"),
        .labelContains(
          app.staticTexts["action-notice"],
          "10 minutes",
          "The configured repeat interval is confirmed"
        ),
        .labelContains(eventStatus, "Snoozed", "The Firestore listener receives the snoozed state"),
        .notExists(app.otherElements["dose-reminder-alert"], "The response screen is dismissed"),
      ]
    )

    XCUIDevice.shared.press(.home)
    let repeatNotification = springboard.descendants(matching: .any)[
      "NotificationShortLookView"
    ]
    let repeatNotificationTitle = springboard.staticTexts["Medication reminder 2"].firstMatch
    XCTAssertTrue(
      repeatNotification.waitForExistence(timeout: TestStepHelper.conditionTimeout),
      "SpringBoard did not receive reminder 2 from the snoozed Firestore event"
    )
    app.terminate()
    try tester.step(
      "repeat-system-notification",
      description: "With MediNag terminated, iOS retains the repeat notification",
      verifications: [
        .exists(repeatNotificationTitle, "The repeat is rendered by SpringBoard"),
      ],
      screenshotElement: repeatNotification
    )

    repeatNotification.tap()
    try tester.step(
      "repeat-reminder-response",
      description: "Tapping reminder 2 cold-launches the app after logical time advances",
      verifications: reminderVerifications(
        app,
        sequence: "REMINDER 2",
        time: environment.repeatDisplayTime
      )
    )

    app.buttons["reminder-yes-i-did"].tap()
    try tester.step(
      "dose-completed-in-firestore",
      description: "Yes, I did completes the real event and cancels further reminders",
      verifications: [
        .labelContains(eventStatus, "Completed", "The Firestore listener receives completion"),
        .labelContains(
          app.staticTexts["action-notice"],
          "cancelled",
          "The app confirms notification cancellation"
        ),
      ]
    )

    try tester.generateDocs()
  }

  private func makeApplication(_ environment: ConnectedEnvironment) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += [
      "-e2e",
      "-e2e-deliver-notification-on-background",
      "-firebase-emulator-project-id", environment.projectID,
      "-firebase-emulator-api-key", environment.apiKey,
      "-firebase-emulator-app-id", environment.appID,
      "-firebase-emulator-messaging-sender-id", environment.messagingSenderID,
      "-firebase-emulator-host", "127.0.0.1",
      "-firebase-auth-emulator-port", "9099",
      "-firebase-firestore-emulator-port", "8080",
      "-AppleLanguages", "(en)",
      "-AppleLocale", "en_CA",
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryM",
      "-NSTreatUnknownArgumentsAsOpen", "NO",
    ]
    app.launchEnvironment["TZ"] = "America/Toronto"
    return app
  }

  private func makeTester(application: XCUIApplication) -> TestStepHelper {
    let tester = TestStepHelper(
      testCase: self,
      application: application,
      storyID: "004-ios-respond-to-dose"
    )
    tester.setMetadata(
      title: "Lori schedules and Steve responds to a dose",
      narrative:
        "As Lori and Steve, we want a dashboard schedule to become an iOS notification and Steve’s response to return to the dashboard."
    )
    tester.documentPriorStep(
      "empty-connected-dashboard",
      index: 0,
      description: "Lori opens a fresh dashboard connected to Firebase",
      verifications: [
        "The dashboard is connected to the isolated Firebase environment",
        "No medication schedule has been preloaded",
      ],
      surface: "web"
    )
    tester.documentPriorStep(
      "schedule-written-to-firestore",
      index: 1,
      description: "Lori saves the medication schedule through the dashboard",
      verifications: [
        "The saved medication label is rendered from the Firestore snapshot",
        "The dashboard confirms the production repository write",
      ],
      surface: "web"
    )
    tester.documentPriorStep(
      "event-observed-on-dashboard",
      index: 2,
      description: "The schedule materializes the pending event Steve will receive",
      verifications: [
        "The pending event arrives through the dashboard Firestore listener",
        "The event is waiting for Steve’s response",
      ],
      surface: "web"
    )
    return tester
  }

  private func reminderVerifications(
    _ app: XCUIApplication,
    sequence: String,
    time: String
  ) -> [StepVerification] {
    [
      .exists(app.otherElements["dose-reminder-alert"], "The response screen is visible"),
      .labelContains(app.staticTexts["reminder-sequence"], sequence, "The reminder sequence is correct"),
      .labelContains(app.staticTexts["reminder-time"], time, "The reminder uses the logical scheduled time"),
      .exists(app.buttons["reminder-yes-i-will"], "Yes, I will is available"),
      .exists(app.buttons["reminder-yes-i-did"], "Yes, I did is available"),
      .sameSize(
        app.buttons["reminder-yes-i-will"],
        app.buttons["reminder-yes-i-did"],
        "Neither response has greater visual weight"
      ),
    ]
  }
}

private struct ConnectedEnvironment {
  let projectID: String
  let apiKey: String
  let appID: String
  let messagingSenderID: String
  let subjectEmail: String
  let subjectPassword: String
  let householdID: String
  let medicationName: String
  let scheduledDisplayTime: String
  let repeatDisplayTime: String

  init() throws {
    projectID = try requiredConfiguration("MEDINAG_E2E_PROJECT_ID")
    apiKey = try requiredConfiguration("MEDINAG_E2E_API_KEY")
    appID = try requiredConfiguration("MEDINAG_E2E_APP_ID")
    messagingSenderID = try requiredConfiguration("MEDINAG_E2E_MESSAGING_SENDER_ID")
    subjectEmail = try requiredConfiguration("MEDINAG_E2E_SUBJECT_EMAIL")
    subjectPassword = try requiredConfiguration("MEDINAG_E2E_SUBJECT_PASSWORD")
    householdID = try requiredConfiguration("MEDINAG_E2E_HOUSEHOLD_ID")
    medicationName = try requiredConfiguration("MEDINAG_E2E_MEDICATION_NAME")
    scheduledDisplayTime = try requiredConfiguration("MEDINAG_E2E_SCHEDULED_DISPLAY_TIME")
    repeatDisplayTime = try requiredConfiguration("MEDINAG_E2E_REPEAT_DISPLAY_TIME")
  }
}

private func requiredConfiguration(_ name: String) throws -> String {
  let bundle = Bundle(for: RespondToDoseUITests.self)
  guard let value = bundle.object(forInfoDictionaryKey: name) as? String, !value.isEmpty else {
    throw XCTSkip("The connected E2E build did not supply \(name).")
  }
  return value
}
