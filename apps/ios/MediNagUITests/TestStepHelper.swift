import XCTest

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
    verifications: [String]
  ) {
    steps.append(
      Step(
        identifier: identifier,
        description: description,
        filename: String(format: "%03d-%@.png", index, identifier),
        verifications: verifications,
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
    verifications: [StepVerification]
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
    let screenshot = XCUIScreen.main.screenshot()
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
        durationMilliseconds: startedAt.duration(to: .now).milliseconds
      )
    )
  }

  func generateDocs() throws {
    let readme = """
      # Test: \(title)

      > \(narrative)

      ## Surface coverage

      - **Web Admin Dashboard:** not-applicable — This story exercises Steve's local iOS response loop.
      - **iOS:** covered
      - **watchOS:** not-applicable — watchOS is deferred until after the iOS MVP.

      ## Deterministic preconditions

      - Fixtures: `scheduled-dose-first-reminder` and `scheduled-dose-repeat-due`
      - Clock: 2026-08-03 08:00 America/Toronto, advanced directly to 08:10 for the repeat
      - Device: iPhone 17 on iOS 26.2, portrait, light appearance, standard Dynamic Type
      - Status bar: hidden in E2E so the runner's real wall clock cannot contradict the fixture
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

      ![\(heading)](./screenshots/ios/\(step.filename))

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
  let durationMilliseconds: Int
}

extension Duration {
  fileprivate var milliseconds: Int {
    let components = self.components
    return Int(components.seconds * 1_000)
      + Int(components.attoseconds / 1_000_000_000_000_000)
  }
}
