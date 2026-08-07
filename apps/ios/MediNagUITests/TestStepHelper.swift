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
}

final class TestStepHelper {
  static let conditionTimeout: TimeInterval = 2

  private unowned let testCase: XCTestCase
  private var title = ""
  private var narrative = ""
  private var steps: [Step] = []

  init(
    testCase: XCTestCase,
    application: XCUIApplication,
    storyID: String
  ) {
    self.testCase = testCase
    _ = application
    _ = storyID
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
    let filename = String(format: "%03d-%@.png", steps.count, identifier)
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
    guard recording else { return }
    let readme = """
      # Test: \(title)

      > \(narrative)

      ## Surface coverage

      - **Web Admin Dashboard:** not-applicable — This story exercises Steve's local iOS response loop.
      - **iOS:** covered
      - **watchOS:** not-applicable — watchOS is deferred until after the iOS MVP.

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

  private var recording: Bool {
    ProcessInfo.processInfo.environment["MEDINAG_RECORD_SCREENSHOTS"] == "1"
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
