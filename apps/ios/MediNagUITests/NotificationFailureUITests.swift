import XCTest

@MainActor
final class NotificationFailureUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  func testDeniedPermissionAlertsAdministrator() throws {
    XCUIDevice.shared.orientation = .portrait
    let environment = try ConnectedEnvironment()
    let app = makeApplication(environment)
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    let tester = TestStepHelper(
      testCase: self,
      application: app,
      storyID: "005-notification-failure"
    )
    app.launch()

    try tester.step(
      "failure-sign-in",
      description: "Steve starts the patient sign-in flow",
      verifications: [
        .exists(app.buttons["patient-google-sign-in"], "Google is the visible patient sign-in action")
      ]
    )
    app.buttons["patient-google-sign-in"].tap()

    try tester.step(
      "failure-authentication",
      description: "MediNag signs into the isolated Firebase Auth Emulator identity",
      verifications: [
        .exists(app.otherElements["authentication-progress-screen"], "The authentication progress state is visible"),
        .exists(app.buttons["continue-after-authentication"], "Steve explicitly continues to schedule selection"),
      ]
    )
    app.buttons["continue-after-authentication"].tap()

    let plan = app.buttons["schedule-option-\(environment.administratorID)"]
    try tester.step(
      "failure-choose-schedule",
      description: "Steve chooses Lori's published schedule",
      verifications: [
        .labelContains(plan, environment.administratorName, "Lori's published plan is visible from Firebase"),
        .labelContains(plan, environment.medicationName, "The published plan identifies the medication"),
      ]
    )
    plan.tap()
    app.buttons["follow-schedule"].tap()

    try tester.step(
      "failure-event-received",
      description: "The iPhone follows Lori's schedule before requesting permission",
      verifications: [
        .labelContains(
          app.staticTexts["next-dose-name"],
          environment.medicationName,
          "The medication event arrives through the Firestore listener"
        ),
        .exists(
          app.buttons["allow-notifications"],
          "The app offers the notification permission action"
        ),
      ]
    )

    app.buttons["allow-notifications"].tap()
    let permissionAlert = springboard.alerts.firstMatch
    try tester.step(
      "failure-permission-prompt",
      description: "iOS asks whether MediNag may send notifications",
      verifications: [
        .exists(permissionAlert, "The notification permission sheet is rendered by iOS"),
        .exists(permissionAlert.buttons["Don’t Allow"], "The system offers a Don't Allow action"),
      ]
    )
    permissionAlert.buttons["Don’t Allow"].tap()

    try tester.step(
      "patient-not-ready",
      description: "Steve sees that medication notifications are disabled",
      verifications: [
        .labelContains(
          app.staticTexts["notification-readiness"],
          "Notifications are disabled",
          "The patient sees that notifications are disabled"
        ),
        .labelContains(
          app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Enable notifications in Settings")
          ).firstMatch,
          "Enable notifications in Settings",
          "The patient is told to enable notifications in Settings"
        ),
        .labelContains(
          app.staticTexts["action-notice"],
          "administrator has been alerted",
          "The client-visible failure is written through Firestore"
        ),
      ]
    )
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
}
