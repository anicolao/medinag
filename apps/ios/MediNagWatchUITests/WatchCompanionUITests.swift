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
      verifications: [.exists(app.staticTexts["watch-setup"], "No schedule or identity is invented on Watch")],
      screenshotElement: app.staticTexts["watch-setup"])
  }

  func testWatchResponsesReachDashboard() async throws {
    let app = XCUIApplication()
    app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_CA"]
    app.launch()
    let system = XCUIApplication(bundleIdentifier: "com.apple.Carousel")
    if system.alerts.firstMatch.waitForExistence(timeout: 2) {
      let allow = system.alerts.firstMatch.buttons["Allow"]
      XCTAssertTrue(allow.exists, "Only the real Watch notification permission is accepted")
      allow.tap()
    }
    let tester = TestStepHelper(testCase: self, application: app, storyID: "006-watch-companion",
      startingStepIndex: 1, surface: "watchos")
    let name = try configuration("MEDINAG_E2E_MEDICATION_NAME")
    try tester.step("watch-dose", description: "WatchConnectivity delivers the actual followed medication dose",
      verifications: [
        .labelContains(app.staticTexts["watch-dose-name"], name, "The Watch shows the dose created through the dashboard"),
        .notExists(app.buttons["watch-refresh"], "The Watch has no dashboard controls"),
        .notExists(app.staticTexts["watch-administrator"], "The administrator header does not crowd the dose"),
      ], screenshotElement: app.otherElements["watch-content"])
    let later = app.buttons["watch-yes-i-will"]
    let taken = app.buttons["watch-yes-i-did"]
    let content = app.otherElements["watch-content"]
    let firstID = try XCTUnwrap((content.value as? String)?.components(separatedBy: "|").first)
    try tester.step("watch-response-actions", description: "The nearby dose has just two equally weighted response buttons",
      verifications: [
        .hittable(taken, "Yes, I did is visible without scrolling"),
        .hittable(later, "Yes, I will is visible without scrolling"),
        .sameSize(taken, later, "Neither response has stronger visual weight"),
      ], screenshotElement: app.otherElements["watch-content"])
    later.tap()
    try tester.step("watch-response-pending", description: "The Watch waits for a server-confirmed response",
      verifications: [.exists(app.staticTexts["watch-progress"], "A pending response is not displayed as saved")],
      screenshotElement: app.otherElements["watch-content"])
    let predicate = NSPredicate(format: "value CONTAINS %@", "|snoozed|1")
    let acknowledged = XCTNSPredicateExpectation(predicate: predicate, object: content)
    XCTAssertEqual(XCTWaiter.wait(for: [acknowledged], timeout: 2), .completed,
      "The real iPhone transaction must acknowledge snooze before another Watch response")
    taken.tap()
    let completed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "NOT (value BEGINSWITH %@)", firstID + "|"), object: content)
    XCTAssertEqual(XCTWaiter.wait(for: [completed], timeout: 2), .completed)
    try tester.step("watch-completed", description: "The server-confirmed completion removes this dose from the Watch",
      verifications: [
        StepVerification(spec: "The completed medication occurrence is no longer the Watch's current dose") {
          guard let value = content.value as? String else { return false }
          return !value.hasPrefix(firstID + "|")
        },
        .notExists(app.staticTexts["watch-progress"], "The phone has acknowledged the completion"),
      ], screenshotElement: app.otherElements["watch-content"])
    // The completion Playwright stage independently verifies both recorded
    // responses against Firestore through the administrator dashboard.
    // Notification sound/routing/dismissal are NOT claimed by this UI story.
  }

  private func configuration(_ key: String) throws -> String {
    guard let value = Bundle(for: Self.self).object(forInfoDictionaryKey: key) as? String,
      !value.isEmpty else { throw NSError(domain: "Missing connected build configuration: \(key)", code: 1) }
    return value
  }
}
