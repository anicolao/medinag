import XCTest
import UIKit

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

  static func hittable(
    _ element: XCUIElement,
    _ spec: String
  ) -> StepVerification {
    StepVerification(spec: spec) {
      let expectation = XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "hittable == true"),
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
    screenshotElement: XCUIElement? = nil,
    trimAnimatedSystemEdge: Bool = false
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
    let attachment: XCTAttachment
    if
      trimAnimatedSystemEdge,
      let image = screenshot.image.cgImage,
      image.width > 60,
      image.height > 60,
      let cropped = image.cropping(
        to: CGRect(
          x: 30,
          y: 30,
          width: image.width - 60,
          height: image.height - 60
        )
      )
    {
      attachment = XCTAttachment(
        image: UIImage(cgImage: normalizeSystemMaterial(cropped))
      )
    } else {
      attachment = XCTAttachment(screenshot: screenshot)
    }
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

  private func normalizeSystemMaterial(_ image: CGImage) -> CGImage {
    // Reduced Transparency still leaves a few near-white SpringBoard material
    // pixels dependent on the fresh simulator's wallpaper raster. Normalize
    // only that background range; notification text, icon, and layout remain
    // untouched and the resulting artifact is compared at zero tolerance.
    let bytesPerPixel = 4
    let bytesPerRow = image.width * bytesPerPixel
    var pixels = [UInt8](repeating: 0, count: image.height * bytesPerRow)
    guard
      let context = CGContext(
        data: &pixels,
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
          | CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else { return image }
    context.draw(
      image,
      in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
    )
    for index in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
      if pixels[index] > 235, pixels[index + 1] > 235, pixels[index + 2] > 235 {
        pixels[index] = 244
        pixels[index + 1] = 248
        pixels[index + 2] = 249
      }
    }
    return context.makeImage() ?? image
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

      - Backend: fresh Firebase Authentication, Firestore, and Functions emulators with production rules and function code
      - Data: Lori creates the schedule through the dashboard; no schedule or medication event is preloaded or encoded in the native test
      - Identity: run-specific Google-provider identities use the Firebase Auth Emulator; this walkthrough does not claim to exercise Google's OAuth consent UI
      - Relationship: the patient discovers and follows the administrator's published plan through the iPhone UI; no relationship document is preloaded
      - Clock: an affine E2E timeline compresses elapsed time before the production scheduler creates its calendar triggers; it never creates or delivers a notification
      - Device: iPhone 17 on iOS 26.5, portrait, light appearance, increased contrast, reduced motion and transparency, medium Dynamic Type
      - Status bar: fixed at 8:00 AM with a Simulator override
      - System UI: notification permission and both reminders are rendered by iOS SpringBoard
      - Lifecycle: the UI test terminates MediNag before it captures or taps either notification
      - Snooze interval: 10 minutes from the administrator profile written through the dashboard

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
