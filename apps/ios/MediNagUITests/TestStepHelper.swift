import XCTest

@MainActor
struct StepVerification {
  let spec: String
  let check: () -> Bool

  static func exists(
    _ element: XCUIElement,
    _ spec: String
  ) -> StepVerification {
    StepVerification(spec: spec) {
      element.waitForExistence(timeout: TestStepHelper.conditionTimeout)
    }
  }

  static func labelContains(
    _ element: XCUIElement,
    _ text: String,
    _ spec: String
  ) -> StepVerification {
    StepVerification(spec: spec) {
      let predicate = NSPredicate(format: "label CONTAINS %@", text)
      let expectation = XCTNSPredicateExpectation(
        predicate: predicate,
        object: element
      )
      return XCTWaiter.wait(
        for: [expectation],
        timeout: TestStepHelper.conditionTimeout
      ) == .completed
    }
  }

  static func notExists(
    _ element: XCUIElement,
    _ spec: String
  ) -> StepVerification {
    StepVerification(spec: spec) {
      let expectation = XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "exists == false"),
        object: element
      )
      return XCTWaiter.wait(
        for: [expectation],
        timeout: TestStepHelper.conditionTimeout
      ) == .completed
    }
  }

  static func sameSize(
    _ first: XCUIElement,
    _ second: XCUIElement,
    _ spec: String
  ) -> StepVerification {
    StepVerification(spec: spec) {
      let firstSize = first.frame.size
      let secondSize = second.frame.size
      return abs(firstSize.width - secondSize.width) < 0.5
        && abs(firstSize.height - secondSize.height) < 0.5
    }
  }
}

@MainActor
final class TestStepHelper {
  static let conditionTimeout: TimeInterval = 2

  private unowned let testCase: XCTestCase
  private var title = ""
  private var narrative = ""
  private var steps: [Step] = []
  private var nextScreenshotIndex: Int

  init(
    testCase: XCTestCase,
    application: XCUIApplication,
    storyID: String,
    startingStepIndex: Int = 0
  ) {
    self.testCase = testCase
    self.nextScreenshotIndex = startingStepIndex
    _ = application
    _ = storyID
  }

  func documentPriorStep(
    _ identifier: String,
    index: Int,
    description: String,
    verifications: [String],
    surface: String
  ) {
    steps.append(
      Step(
        identifier: identifier,
        description: description,
        filename: String(format: "%03d-%@.png", index, identifier),
        verifications: verifications,
        surface: surface,
        durationMilliseconds: 0
      )
    )
  }

  func setMetadata(title: String, narrative: String) {
    self.title = title
    self.narrative = narrative
  }

  func step(
    _ identifier: String,
    description: String,
    verifications: [StepVerification],
    screenshotElement: XCUIElement? = nil
  ) throws {
    let startedAt = ContinuousClock.now
    for verification in verifications {
      XCTAssertTrue(
        verification.check(),
        verification.spec,
        file: #filePath,
        line: #line
      )
    }
    let filename = String(format: "%03d-%@.png", nextScreenshotIndex, identifier)
    nextScreenshotIndex += 1
    let screenshot = screenshotElement?.screenshot() ?? XCUIScreen.main.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = filename
    attachment.lifetime = .keepAlways
    testCase.add(attachment)

    steps.append(
      Step(
        identifier: identifier,
        description: description,
        filename: filename,
        verifications: verifications.map(\.spec),
        surface: "ios",
        durationMilliseconds: startedAt.duration(to: .now).milliseconds
      )
    )
  }

  func generateDocs() throws {
    let readme = """
      # Test: \(title)

      > \(narrative)

      ## Surface coverage

      - **Web Admin Dashboard:** covered
      - **iOS:** covered
      - **watchOS:** not-applicable — watchOS is deferred until after the iOS MVP.

      ## Deterministic preconditions

      - Backend: a fresh Firebase Authentication and Firestore emulator suite with security rules enabled
      - Data: Lori creates the schedule through the dashboard; no schedule or medication event is preloaded or encoded in the native test
      - Identity: advisor and subject credentials are generated for the run through Firebase Auth
      - Clock: notification delivery is advanced on the app-background event; logical reminder times remain derived from the Firestore event
      - Device: iPhone 17 on iOS 26.5, portrait, light appearance, increased contrast, medium Dynamic Type
      - Status bar: fixed at 8:00 AM with a Simulator override
      - System UI: notification permission and both reminders are rendered by iOS SpringBoard
      - Lifecycle: the UI test terminates MediNag before it captures or taps either notification
      - Snooze interval: 10 minutes from `DoseCoordinator.defaultSnoozeInterval`

      \(steps.map(markdown).joined(separator: "\n\n"))
      """
    let attachment = XCTAttachment(
      data: Data(readme.utf8),
      uniformTypeIdentifier: "public.plain-text"
    )
    attachment.name = "README.md"
    attachment.lifetime = .keepAlways
    testCase.add(attachment)
  }

  private func markdown(_ step: Step) -> String {
    let heading = step.description
    let checks = step.verifications.map { "- [x] \($0)" }.joined(separator: "\n")
    return """
      ## \(heading)

      ![\(heading)](./screenshots/\(step.surface)/\(step.filename))

      **Verifications:**

      \(checks)
      """
  }
}

private struct Step {
  let identifier: String
  let description: String
  let filename: String
  let verifications: [String]
  let surface: String
  let durationMilliseconds: Int
}

extension Duration {
  fileprivate var milliseconds: Int {
    let components = self.components
    return Int(components.seconds * 1_000)
      + Int(components.attoseconds / 1_000_000_000_000_000)
  }
}
