import XCTest

@MainActor
final class RespondToDoseUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  func testConnectedSystemNotificationDoseLoop() async throws {
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

    try tester.step(
      "schedule-connection-in-progress",
      description: "MediNag connects Steve to Lori's published schedule",
      verifications: [
        .exists(
          app.otherElements["schedule-connection-progress-screen"],
          "A visible connection state appears before the two-second condition limit"
        ),
        .exists(
          app.buttons["continue-after-following"],
          "Steve controls when to continue while backend events materialize"
        ),
      ]
    )
    app.buttons["continue-after-following"].tap()

    let eventStatus = eventStatusElement(in: app)
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
      description: "iOS asks Steve to allow MediNag alarms",
      verifications: [
        .exists(permissionAlert, "The permission prompt is rendered by iOS"),
        .exists(permissionAlert.buttons["Allow"], "The system offers an Allow action"),
      ]
    )
    permissionAlert.buttons["Allow"].tap()

    try tester.step(
      "waiting-for-first-reminder",
      description: "MediNag is ready while iOS owns the scheduled alarm",
      verifications: [
        .labelContains(
          app.staticTexts["notification-readiness"],
          "Reminders are ready",
          "Alarm permission and real scheduled AlarmKit alarms are confirmed"
        ),
        .labelContains(
          app.staticTexts["next-dose-name"],
          environment.medicationName,
          "The Firestore event remains visible while the app waits"
        ),
        .notExists(app.buttons["yes-i-will"], "No response is available before an alarm"),
        .notExists(app.buttons["yes-i-did"], "No completion is available before an alarm"),
      ],
      screenshotElement: app.otherElements["reminder-diagnostics"]
    )

    XCUIDevice.shared.press(.home)
    try tester.step(
      "app-backgrounded",
      description: "MediNag is backgrounded while the alarm remains owned by iOS",
      verifications: [
        .exists(springboard.icons["MediNag"], "The Home Screen confirms MediNag is backgrounded"),
      ],
      screenshotCrop: .belowSystemAlarm
    )
    let firstAlertObserved = try await waitForAlarmSignal(
      "alert", after: 0, environment: environment
    )
    expandSystemAlarm(in: springboard)
    try tester.step(
      "first-system-alarm",
      description: "While MediNag is backgrounded, iOS sounds and presents the scheduled alarm",
      verifications: [
        StepVerification(spec: "iOS requests the first system-owned AlarmKit alert") {
          firstAlertObserved
        },
      ],
      screenshotCrop: .systemAlarmWithoutAnimatedGlyph
    )

    tapSystemAlarm(in: springboard)
    XCTAssertTrue(
      app.wait(for: .runningForeground, timeout: TestStepHelper.conditionTimeout),
      "Responding to the AlarmKit alert did not foreground MediNag"
    )
    try tester.step(
      "first-reminder-response",
      description: "Tapping the system alarm immediately opens the medication response",
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
        .labelContains(
          eventStatusElement(in: app),
          "Snoozed",
          "The Firestore listener receives the snoozed state"
        ),
        .notExists(app.otherElements["dose-reminder-alert"], "The response screen is dismissed"),
        .labelContains(
          app.staticTexts["notification-readiness"],
          "Reminders are ready",
          "iOS confirms the repeat alarm registration"
        ),
      ],
      screenshotElement: app.otherElements["next-dose-card"]
    )

    app.terminate()
    let repeatAlertObserved = try await waitForAlarmSignal(
      "alert", after: 1, environment: environment
    )
    expandSystemAlarm(in: springboard)
    try tester.step(
      "repeat-system-alarm",
      description: "With MediNag terminated, iOS retains and sounds the repeat alarm",
      verifications: [
        StepVerification(spec: "iOS requests the repeat system-owned AlarmKit alert") {
          repeatAlertObserved
        },
      ],
      screenshotCrop: .systemAlarmWithoutAnimatedGlyph
    )

    tapSystemAlarm(in: springboard)
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
        .labelContains(
          eventStatusElement(in: app),
          "Completed",
          "The Firestore listener receives completion"
        ),
        .labelContains(
          app.staticTexts["action-notice"],
          "cancelled",
          "The app confirms notification cancellation"
        ),
      ]
    )

  }

  private func makeApplication(_ environment: ConnectedEnvironment) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += [
      "-e2e",
      "-e2e-logical-now", environment.logicalNow,
      "-e2e-time-scale", "0.003",
      "-firebase-emulator-project-id", environment.projectID,
      "-firebase-emulator-api-key", environment.apiKey,
      "-firebase-emulator-app-id", environment.appID,
      "-firebase-emulator-messaging-sender-id", environment.messagingSenderID,
      "-firebase-emulator-host", "127.0.0.1",
      "-firebase-auth-emulator-port", environment.authPort,
      "-firebase-firestore-emulator-port", environment.firestorePort,
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

  private func eventStatusElement(in app: XCUIApplication) -> XCUIElement {
    app.staticTexts.matching(
      NSPredicate(
        format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
        "event-",
        "-status"
      )
    ).firstMatch
  }

  private func makeTester(application: XCUIApplication) -> TestStepHelper {
    TestStepHelper(
      testCase: self,
      application: application,
      storyID: "004-ios-respond-to-dose"
    )
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
          "The repeat retains the medication occurrence time"
        ),
        at: 2
      )
    }
    return verifications
  }

  private func waitForAlarmSignal(
    _ event: String,
    after count: Int,
    environment: ConnectedEnvironment
  ) async throws -> Bool {
    var request = URLRequest(
      url: URL(
        string: "http://127.0.0.1:\(environment.alarmMonitorPort)/wait/\(event)?after=\(count)"
      )!
    )
    request.timeoutInterval = TestStepHelper.conditionTimeout
    let (_, response) = try await URLSession.shared.data(for: request)
    return (response as? HTTPURLResponse)?.statusCode == 200
  }

  private func expandSystemAlarm(in springboard: XCUIApplication) {
    // AlarmKit's compact Dynamic Island is outside the XCTest accessibility
    // tree. A long press exposes the real system alarm before the walkthrough
    // records it, just as a person does on the device.
    springboard.coordinate(
      withNormalizedOffset: CGVector(dx: 0.5, dy: 0.04)
    ).press(forDuration: 0.8)
  }

  private func tapSystemAlarm(in springboard: XCUIApplication) {
    // Tapping the expanded system alarm opens its owning app. MediNag then
    // resolves the alerting AlarmKit ID to the Firestore medication event.
    springboard.coordinate(
      withNormalizedOffset: CGVector(dx: 0.5, dy: 0.07)
    ).tap()
  }

}

struct ConnectedEnvironment {
  let projectID: String
  let apiKey: String
  let appID: String
  let messagingSenderID: String
  let googleIDTokenBase64: String
  let authPort: String
  let firestorePort: String
  let alarmMonitorPort: String
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
    authPort = try requiredConfiguration("MEDINAG_E2E_AUTH_PORT")
    firestorePort = try requiredConfiguration("MEDINAG_E2E_FIRESTORE_PORT")
    alarmMonitorPort = try requiredConfiguration("MEDINAG_E2E_ALARM_MONITOR_PORT")
    administratorID = try requiredConfiguration("MEDINAG_E2E_ADMINISTRATOR_ID")
    administratorName = try requiredConfiguration("MEDINAG_E2E_ADMINISTRATOR_NAME")
    medicationName = try requiredConfiguration("MEDINAG_E2E_MEDICATION_NAME")
    timeZoneIdentifier = try requiredConfiguration("MEDINAG_E2E_TIME_ZONE")
    let configuredNow = try requiredConfiguration("MEDINAG_E2E_LOGICAL_NOW")
    guard let now = ISO8601DateFormatter().date(from: configuredNow) else {
      throw XCTSkip("The connected E2E logical clock is invalid.")
    }
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
      after: now,
      matching: DateComponents(hour: hour, minute: minute),
      matchingPolicy: .nextTime
    ) else {
      throw XCTSkip("The first connected occurrence could not be resolved.")
    }
    logicalNow = ISO8601DateFormatter().string(
      // Five logical minutes are 0.9 real seconds at the E2E scale, and the
      // configured ten-minute snooze is 1.8 seconds. The clock only compresses
      // dates supplied to the production AlarmKit scheduler; iOS still owns,
      // renders, sounds, and routes both alarms.
      from: firstOccurrence.addingTimeInterval(-5 * 60)
    )
  }
}

func requiredConfiguration(_ name: String) throws -> String {
  let bundle = Bundle(for: RespondToDoseUITests.self)
  guard let value = bundle.object(forInfoDictionaryKey: name) as? String, !value.isEmpty else {
    throw XCTSkip("The connected E2E build did not supply \(name).")
  }
  return value
}
