import XCTest
import UIKit

@MainActor
final class RespondToDoseUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  func testConnectedSystemNotificationDoseLoop() async throws {
    let reduceMotion = UIAccessibility.isReduceMotionEnabled
    let reduceTransparency = UIAccessibility.isReduceTransparencyEnabled
    XCTAssertTrue(reduceMotion)
    XCTAssertTrue(reduceTransparency)
    XCUIDevice.shared.orientation = .portrait
    let environment = try ConnectedEnvironment()
    let app = environment.makeApplication()
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

    let occurrenceStatusIdentifier = eventStatus.identifier
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

    try tester.step("waiting-for-first-reminder",
      description: "iOS confirms the bounded queue of real actionable notifications",
      verifications: [
        .labelContains(pendingReminderCountElement(in: app), "60 of 60", "All pending requests are confirmed by UserNotifications"),
      ], screenshotElement: app.otherElements["reminder-diagnostics"])

    XCUIDevice.shared.press(.home)
    openNotificationCenter(in: springboard)
    let first = medicationNotification(in: springboard, name: environment.medicationName)
    try tester.step("first-system-notification",
      description: "The actual medication notification appears while the app is backgrounded",
      verifications: [.exists(first, "SpringBoard displays the notification created by the production scheduler")],
      screenshotElement: first)
    first.press(forDuration: 0.5)
    try tester.step("notification-response-actions",
      description: "The expanded system notification offers both medication responses",
      verifications: [
        .exists(springboard.buttons["Yes, I did"], "Completion is a real system notification action"),
        .exists(springboard.buttons["Yes, I will"], "Snooze is a real system notification action"),
      ])
    springboard.buttons["Yes, I will"].tap()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 2))
    try tester.step("dose-snoozed-in-firestore",
      description: "The notification action records the snooze through the real Firestore transaction",
      verifications: [
        .labelContains(app.staticTexts["snooze-count"], "1", "The server-backed snooze count increments"),
        .labelContains(app.staticTexts["action-notice"], "10 minutes", "The configured snooze interval is confirmed"),
        .labelContains(pendingReminderCountElement(in: app), "60 of 60", "The replacement queue is confirmed by iOS"),
      ])
    app.terminate()
    openNotificationCenter(in: springboard)
    let repeated = medicationNotification(in: springboard, name: environment.medicationName)
    try tester.step("repeat-system-notification",
      description: "A scheduled snooze-expiry notification is delivered with MediNag terminated",
      verifications: [.exists(repeated, "SpringBoard renders the real repeat, not a test-generated delivery")],
      screenshotElement: repeated)
    repeated.press(forDuration: 0.5)
    XCTAssertTrue(springboard.buttons["Yes, I did"].waitForExistence(timeout: 2))
    springboard.buttons["Yes, I did"].tap()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 2))
    try tester.step("dose-completed-in-firestore",
      description: "The notification action cold-launches MediNag and completes the dose",
      verifications: [
        .labelContains(app.staticTexts[occurrenceStatusIdentifier], "Completed", "The Firestore listener receives completion"),
        .labelContains(app.staticTexts["action-notice"], "cancelled", "The app confirms reconciliation after cancellation"),
      ])

  }

}

@MainActor
extension ConnectedEnvironment {
  func makeApplication() -> XCUIApplication {
    let environment = self
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
}

@MainActor
extension RespondToDoseUITests {

  private func eventStatusElement(in app: XCUIApplication) -> XCUIElement {
    app.staticTexts.matching(
      NSPredicate(
        format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
        "event-",
        "-status"
      )
    ).firstMatch
  }

  private func pendingReminderCountElement(in app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any).matching(
      identifier: "pending-reminder-count"
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

  private func openNotificationCenter(in springboard: XCUIApplication) {
    springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.01))
      .press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)))
  }

  private func medicationNotification(in springboard: XCUIApplication, name: String) -> XCUIElement {
    springboard.staticTexts.matching(NSPredicate(
      format: "label CONTAINS %@", name
    )).firstMatch
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
