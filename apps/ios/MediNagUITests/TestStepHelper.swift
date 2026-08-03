import CoreGraphics
import UIKit
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
  private let application: XCUIApplication
  private let storyID: String
  private var title = ""
  private var narrative = ""
  private var steps: [Step] = []

  init(
    testCase: XCTestCase,
    application: XCUIApplication,
    storyID: String
  ) {
    self.testCase = testCase
    self.application = application
    self.storyID = storyID
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

    try verifyOrRecord(screenshot: screenshot, filename: filename)
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
    try readme.write(
      to: storyRoot.appending(path: "README.md"),
      atomically: true,
      encoding: .utf8
    )
  }

  private var repositoryRoot: URL {
    get throws {
      guard let value = ProcessInfo.processInfo.environment["MEDINAG_E2E_ROOT"] else {
        throw TestStepError.missingRepositoryRoot
      }
      return URL(filePath: value, directoryHint: .isDirectory)
    }
  }

  private var storyRoot: URL {
    get throws {
      try repositoryRoot
        .appending(path: "tests/e2e/\(storyID)", directoryHint: .isDirectory)
    }
  }

  private var screenshotRoot: URL {
    get throws {
      try storyRoot
        .appending(path: "screenshots/ios", directoryHint: .isDirectory)
    }
  }

  private var recording: Bool {
    ProcessInfo.processInfo.environment["MEDINAG_RECORD_SCREENSHOTS"] == "1"
  }

  private func verifyOrRecord(
    screenshot: XCUIScreenshot,
    filename: String
  ) throws {
    let fileManager = FileManager.default
    let target = try screenshotRoot.appending(path: filename)
    if recording {
      try fileManager.createDirectory(
        at: try screenshotRoot,
        withIntermediateDirectories: true
      )
      try screenshot.pngRepresentation.write(to: target, options: .atomic)
      return
    }

    guard
      let baselineData = try? Data(contentsOf: target),
      let baseline = UIImage(data: baselineData)?.cgImage,
      let actual = UIImage(data: screenshot.pngRepresentation)?.cgImage
    else {
      throw TestStepError.missingBaseline(target.path())
    }
    let baselinePixels = try canonicalPixels(baseline)
    let actualPixels = try canonicalPixels(actual)
    guard
      baseline.width == actual.width,
      baseline.height == actual.height,
      baselinePixels == actualPixels
    else {
      throw TestStepError.pixelDifference(filename)
    }
  }

  private func canonicalPixels(_ image: CGImage) throws -> Data {
    let width = image.width
    let height = image.height
    let bytesPerRow = width * 4
    var data = Data(count: bytesPerRow * height)
    let rendered = data.withUnsafeMutableBytes { buffer in
      guard
        let address = buffer.baseAddress,
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
        let context = CGContext(
          data: address,
          width: width,
          height: height,
          bitsPerComponent: 8,
          bytesPerRow: bytesPerRow,
          space: colorSpace,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
      else {
        return false
      }
      context.interpolationQuality = .none
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    guard rendered else { throw TestStepError.cannotDecodeScreenshot }
    return data
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

private enum TestStepError: LocalizedError {
  case missingRepositoryRoot
  case missingBaseline(String)
  case pixelDifference(String)
  case cannotDecodeScreenshot

  var errorDescription: String? {
    switch self {
    case .missingRepositoryRoot:
      "MEDINAG_E2E_ROOT must point to the repository checkout."
    case .missingBaseline(let path):
      "Missing exact screenshot baseline at \(path)."
    case .pixelDifference(let filename):
      "Screenshot \(filename) differs by at least one pixel."
    case .cannotDecodeScreenshot:
      "The screenshot could not be decoded into canonical RGBA pixels."
    }
  }
}

extension Duration {
  fileprivate var milliseconds: Int {
    let components = self.components
    return Int(components.seconds * 1_000)
      + Int(components.attoseconds / 1_000_000_000_000_000)
  }
}
