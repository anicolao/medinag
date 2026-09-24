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
      "patient-sign-in",
      description: "Steve signs into MediNag with Google",
      verifications: [
        .exists(app.buttons["patient-google-sign-in"], "Google is the only sign-in action"),
        .notExists(app.textFields["household-id"], "No household identifier is requested"),
      ]
    )

    app.buttons["patient-google-sign-in"].tap()

    try tester.step(
      "authentication-in-progress",
      description: "MediNag signs into the isolated Firebase Auth Emulator identity",
      verifications: [
        .exists(
          app.otherElements["authentication-progress-screen"],
          "A visible progress state appears before the two-second condition limit"
        ),
        .exists(
          app.buttons["continue-after-authentication"],
          "The user controls when to continue to schedule selection"
        ),
      ]
    )
    app.buttons["continue-after-authentication"].tap()

    let planOption = app.buttons["schedule-option-\(environment.administratorID)"]
    try tester.step(
      "choose-schedule",
      description: "Steve finds Lori's published schedule",
      verifications: [
        .exists(app.otherElements["schedule-selection-screen"], "The schedule chooser is visible"),
        .labelContains(planOption, environment.administratorName, "Lori is discoverable by name"),
        .labelContains(planOption, environment.medicationName, "The published dose summary identifies the plan"),
      ]
    )
    planOption.tap()
    app.buttons["follow-schedule"].tap()

    let eventStatus = app.staticTexts.matching(
      NSPredicate(
        format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
        "event-",
        "-status"
      )
    ).firstMatch
    try tester.step(
      "firestore-event-received",
      description: "The iPhone follows Lori's schedule and receives its Firestore event",
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
          "Permission and real pending iOS requests are both confirmed"
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
    app.terminate()
    let firstNotification = springboard.descendants(matching: .any)[
      "NotificationShortLookView"
    ]
    let firstNotificationTitle = springboard.staticTexts["Medication reminder"].firstMatch
    XCTAssertTrue(
      firstNotification.waitForExistence(timeout: TestStepHelper.conditionTimeout),
      "SpringBoard did not receive the notification built from the Firestore event"
    )
    try tester.step(
      "first-system-notification",
      description: "With MediNag terminated, iOS retains the scheduled notification",
      verifications: [
        .exists(firstNotificationTitle, "The first reminder is rendered by SpringBoard"),
        .hittable(firstNotification, "The SpringBoard notification has finished arriving"),
      ],
      screenshotElement: firstNotification,
      trimAnimatedSystemEdge: true
    )

    firstNotification.tap()
    XCTAssertTrue(
      app.wait(for: .runningForeground, timeout: TestStepHelper.conditionTimeout),
      "Tapping the first notification did not cold-launch MediNag"
    )
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
    app.terminate()
    let repeatNotification = springboard.descendants(matching: .any)[
      "NotificationShortLookView"
    ]
    let repeatNotificationTitle = springboard.staticTexts["Medication reminder 2"].firstMatch
    XCTAssertTrue(
      repeatNotification.waitForExistence(timeout: TestStepHelper.conditionTimeout),
      "SpringBoard did not receive reminder 2 from the snoozed Firestore event"
    )
    try tester.step(
      "repeat-system-notification",
      description: "With MediNag terminated, iOS retains the repeat notification",
      verifications: [
        .exists(repeatNotificationTitle, "The repeat is rendered by SpringBoard"),
        .hittable(repeatNotification, "The repeat notification has finished arriving"),
      ],
      screenshotElement: repeatNotification,
      trimAnimatedSystemEdge: true
    )

    repeatNotification.tap()
    XCTAssertTrue(
      app.wait(for: .runningForeground, timeout: TestStepHelper.conditionTimeout),
      "Tapping reminder 2 did not cold-launch MediNag"
    )
    try tester.step(
      "repeat-reminder-response",
      description: "Tapping reminder 2 cold-launches the app after logical time advances",
      verifications: reminderVerifications(
        app,
        sequence: "REMINDER 2",
        time: nil
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

    tester.documentPriorStep(
      "completion-returned-to-dashboard",
      index: 2,
      description: "Lori sees Steve's completion and healthy iPhone coverage",
      verifications: [
        "The dashboard Firestore listener receives the completed occurrence",
        "The administrator sees matching pending-request coverage from iOS",
        "No reminder-system incident remains open",
      ],
      surface: "web"
    )

    try tester.generateDocs()
  }

  private func makeApplication(_ environment: ConnectedEnvironment) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += [
      "-e2e",
      "-e2e-logical-now", environment.logicalNow,
      "-e2e-time-scale", "0.01",
      "-firebase-emulator-project-id", environment.projectID,
      "-firebase-emulator-api-key", environment.apiKey,
      "-firebase-emulator-app-id", environment.appID,
      "-firebase-emulator-messaging-sender-id", environment.messagingSenderID,
      "-firebase-emulator-host", "127.0.0.1",
      "-firebase-auth-emulator-port", "9099",
      "-firebase-firestore-emulator-port", "8080",
      "-e2e-google-id-token-base64", environment.googleIDTokenBase64,
      "-e2e-time-zone", environment.timeZoneIdentifier,
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
        "No dose or medication event has been preloaded",
      ],
      surface: "web"
    )
    tester.documentPriorStep(
      "schedule-written-to-firestore",
      index: 1,
      description: "Lori saves and publishes the medication schedule through the dashboard",
      verifications: [
        "The saved medication label is rendered from the Firestore snapshot",
        "The dashboard confirms the production repository write",
        "The plan is explicitly published before the iPhone can discover it",
      ],
      surface: "web"
    )
    return tester
  }

  private func reminderVerifications(
    _ app: XCUIApplication,
    sequence: String,
    time: String?
  ) -> [StepVerification] {
    var verifications: [StepVerification] = [
      .exists(app.otherElements["dose-reminder-alert"], "The response screen is visible"),
      .labelContains(app.staticTexts["reminder-sequence"], sequence, "The reminder sequence is correct"),
      .exists(app.buttons["reminder-yes-i-will"], "Yes, I will is available"),
      .exists(app.buttons["reminder-yes-i-did"], "Yes, I did is available"),
      .sameSize(
        app.buttons["reminder-yes-i-will"],
        app.buttons["reminder-yes-i-did"],
        "Neither response has greater visual weight"
      ),
    ]
    if let time {
      verifications.insert(
        .labelContains(
          app.staticTexts["reminder-time"],
          time,
          "The first reminder uses the medication occurrence time"
        ),
        at: 2
      )
    } else {
      verifications.insert(
        .exists(
          app.staticTexts["reminder-time"],
          "The repeat displays the response-relative snooze expiry"
        ),
        at: 2
      )
    }
    return verifications
  }

}

private struct ConnectedEnvironment {
  let projectID: String
  let apiKey: String
  let appID: String
  let messagingSenderID: String
  let googleIDTokenBase64: String
  let administratorID: String
  let administratorName: String
  let medicationName: String
  let scheduledDisplayTime: String
  let timeZoneIdentifier: String
  let logicalNow: String

  init() throws {
    projectID = try requiredConfiguration("MEDINAG_E2E_PROJECT_ID")
    apiKey = try requiredConfiguration("MEDINAG_E2E_API_KEY")
    appID = try requiredConfiguration("MEDINAG_E2E_APP_ID")
    messagingSenderID = try requiredConfiguration("MEDINAG_E2E_MESSAGING_SENDER_ID")
    googleIDTokenBase64 = try requiredConfiguration(
      "MEDINAG_E2E_GOOGLE_ID_TOKEN_BASE64"
    )
    administratorID = try requiredConfiguration("MEDINAG_E2E_ADMINISTRATOR_ID")
    administratorName = try requiredConfiguration("MEDINAG_E2E_ADMINISTRATOR_NAME")
    medicationName = try requiredConfiguration("MEDINAG_E2E_MEDICATION_NAME")
    timeZoneIdentifier = try requiredConfiguration("MEDINAG_E2E_TIME_ZONE")
    let scheduledTime = try requiredConfiguration("MEDINAG_E2E_SCHEDULED_TIME")
    guard
      let timeZone = TimeZone(identifier: timeZoneIdentifier),
      scheduledTime.count == 5,
      let hour = Int(scheduledTime.prefix(2)),
      let minute = Int(scheduledTime.suffix(2))
    else {
      throw XCTSkip("The connected E2E schedule time is invalid.")
    }
    scheduledDisplayTime = String(format: "%d:%02d", hour, minute)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    guard let firstOccurrence = calendar.nextDate(
      after: Date(),
      matching: DateComponents(hour: hour, minute: minute),
      matchingPolicy: .nextTime
    ) else {
      throw XCTSkip("The first connected occurrence could not be resolved.")
    }
    logicalNow = ISO8601DateFormatter().string(
      // Ten logical minutes are six real seconds at the E2E scale. That leaves
      // enough time to verify iOS accepted the requests and terminate the app,
      // while both the first alert and the configured ten-minute snooze still
      // arrive inside their two-second condition limits. The production
      // scheduler and calendar trigger remain unchanged.
      from: firstOccurrence.addingTimeInterval(-10 * 60)
    )
  }
}

private func requiredConfiguration(_ name: String) throws -> String {
  let bundle = Bundle(for: RespondToDoseUITests.self)
  guard let value = bundle.object(forInfoDictionaryKey: name) as? String, !value.isEmpty else {
    throw XCTSkip("The connected E2E build did not supply \(name).")
  }
  return value
}
