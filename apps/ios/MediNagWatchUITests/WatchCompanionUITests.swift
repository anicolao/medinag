import Foundation
import XCTest

@MainActor
final class WatchCompanionUITests: XCTestCase {
  override func setUp() { continueAfterFailure = false }

  func testUnconfiguredWatch() throws {
    let app = XCUIApplication()
    app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_CA"]
    app.launch()
    let tester = TestStepHelper(testCase: self, application: app, storyID: "006-watch-companion", surface: "watchos")
    try tester.step("watch-setup", description: "The Watch asks for setup on the paired iPhone",
                    verifications: [
                      .exists(app.staticTexts["watch-setup"], "No schedule or identity is invented on Watch"),
                    ],
                    screenshotElement: app.otherElements["watch-setup-instructions"])
  }

  func testWatchResponsesReachDashboard() async throws {
    let app = XCUIApplication()
    app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_CA"]
    app.launch()
    let tester = TestStepHelper(testCase: self, application: app, storyID: "006-watch-companion",
                                startingStepIndex: 1, surface: "watchos")
    app.swipeUp()
    let refresh = app.buttons["watch-refresh"]
    try tester.step("watch-refresh-schedule", description: "The patient refreshes the Watch schedule from the paired iPhone",
                    verifications: [.hittable(refresh, "The public Refresh from iPhone action is ready")],
                    screenshotElement: refresh)
    refresh.tap()
    app.swipeDown()
    let name = try configuration("MEDINAG_E2E_MEDICATION_NAME")
    try tester.step("watch-dose", description: "WatchConnectivity delivers the actual followed medication dose",
                    verifications: [
                      .labelContains(app.staticTexts["watch-dose-name"], name, "Watch shows the dose created through the dashboard"),
                      .labelContains(app.staticTexts["watch-alarm-readiness"], "Alarms managed by iPhone", "Watch explains that its paired iPhone owns the alarms"),
                    ],
                    screenshotElement: app.scrollViews["watch-content"], screenshotCrop: .watchApplicationContent)
    revealResponseActions(in: app)
    let later = app.buttons["watch-yes-i-will"]
    let taken = app.buttons["watch-yes-i-did"]
    try tester.step("watch-response-actions", description: "Both Watch response actions have equal weight",
                    verifications: [
                      .hittable(taken, "Yes, I did is available on Watch"),
                      .hittable(later, "Yes, I will is available on Watch"),
                      .sameSize(taken, later, "Neither Watch response is a default or stronger action"),
                    ], screenshotElement: taken)
    try tester.step("watch-choose-snooze", description: "The patient chooses the equally weighted Watch snooze action",
                    verifications: [.hittable(later, "The actual Yes, I will control is ready to tap")],
                    screenshotElement: later)
    later.tap()
    XCTAssertTrue(app.staticTexts["watch-dose-status"].waitForExistence(timeout: 2))
    let port = try configuration("MEDINAG_E2E_ALARM_MONITOR_PORT")
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/wait/alert?after=1")!)
    request.timeoutInterval = 2
    let (_, response) = try await URLSession.shared.data(for: request)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, "iOS must emit the actual repeat alarm")
    app.swipeDown()
    try tester.step("watch-repeat", description: "A confirmed Watch snooze produces a real repeat iOS alarm",
                    verifications: [.labelContains(app.staticTexts["watch-dose-status"], "Snoozed · 1", "The phone confirms the Firestore snooze rather than optimistic Watch state")],
                    screenshotElement: app.scrollViews["watch-content"], screenshotCrop: .watchApplicationContent)
    revealResponseActions(in: app)
    XCTAssertTrue(taken.waitForExistence(timeout: 2))
    taken.tap()
    try tester.step("watch-completion-pending", description: "Watch displays progress while awaiting the real phone response",
                    verifications: [.labelContains(app.staticTexts["watch-notice"], "Connecting to iPhone", "The patient sees an actual in-flight confirmation state")],
                    screenshotElement: app.staticTexts["watch-notice"])
    let completed = app.staticTexts.matching(NSPredicate(
      format: "identifier BEGINSWITH %@", "watch-completed-"
    )).firstMatch
    try tester.step("watch-server-completed", description: "The server-acknowledged completed event reaches Watch",
                    verifications: [.labelContains(completed, "Completed", "The real server transaction has completed before the final alarm acknowledgement")],
                    screenshotElement: completed)
    let notice = app.staticTexts["watch-notice"]
    try tester.step("watch-completed", description: "The phone confirms completion from the Watch response",
                    verifications: [.labelContains(notice, "Dose complete", "Completion is acknowledged only after the real Firestore write and alarm reconciliation")],
                    screenshotElement: app.scrollViews["watch-content"], screenshotCrop: .watchApplicationContent)
  }

  private func configuration(_ key: String) throws -> String {
    guard let value = Bundle(for: Self.self).object(forInfoDictionaryKey: key) as? String,
          !value.isEmpty else { throw NSError(domain: "Missing connected build configuration: \(key)", code: 1) }
    return value
  }

  private func revealResponseActions(in app: XCUIApplication) {
    let taken = app.buttons["watch-yes-i-did"]
    let later = app.buttons["watch-yes-i-will"]
    XCTAssertTrue(taken.waitForExistence(timeout: 2))
    XCTAssertTrue(later.waitForExistence(timeout: 2))
    // Scroll the actual controls into the usable Watch viewport. A full swipe
    // can put the first button underneath the native navigation header.
    let safeTop: CGFloat = 64
    // Leave room for the live connection/confirmation message below the buttons.
    let safeBottom = app.frame.height - 32
    var pointsPerTurn: CGFloat = 400
    for index in 0..<8 {
      let bounds = taken.frame.union(later.frame)
      if bounds.minY >= safeTop && bounds.maxY <= safeBottom { return }
      let distance = bounds.midY - (safeTop + safeBottom) / 2
      let turn: CGFloat = index == 0 ? (distance > 0 ? 0.05 : -0.05)
        : min(max(distance / pointsPerTurn * 0.9, -1), 1)
      XCUIDevice.shared.rotateDigitalCrown(delta: turn)
      let moved = abs(taken.frame.union(later.frame).midY - bounds.midY)
      if moved > 0.25 {
        pointsPerTurn = max(20, moved / abs(turn))
      }
    }
    XCTAssertGreaterThanOrEqual(taken.frame.union(later.frame).minY, safeTop)
    XCTAssertLessThanOrEqual(taken.frame.union(later.frame).maxY, safeBottom)
  }
}
