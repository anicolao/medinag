import XCTest
import UIKit

enum WalkthroughScreenshotCrop {
  case none
  case systemAppIconInterior
  case systemAlarmWithoutAnimatedGlyph
}

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
  private let claims: ClaimsManifest
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
    let expectedStoryId = "US-\(storyID.prefix(3))"
    guard
      let url = Bundle(for: type(of: testCase)).url(
        forResource: "\(storyID)-claims",
        withExtension: "json"
      ),
      let data = try? Data(contentsOf: url),
      let claims = try? JSONDecoder().decode(ClaimsManifest.self, from: data),
      claims.storyId == expectedStoryId
    else {
      fatalError("The US-004 claims manifest is missing or invalid.")
    }
    self.claims = claims
  }

  func step(
    _ identifier: String,
    description: String,
    verifications: [StepVerification],
    screenshotElement: XCUIElement? = nil,
    screenshotCrop: WalkthroughScreenshotCrop = .none
  ) throws {
    guard let manifestStep = claims.steps.first(where: {
      $0.id == identifier && $0.surface == "ios"
    }) else {
      XCTFail("No claims-manifest step matches ios:\(identifier).")
      return
    }
    XCTAssertEqual(
      description,
      manifestStep.description,
      "Step \(identifier) description must come from claims.json."
    )
    XCTAssertEqual(
      verifications.count,
      manifestStep.claims.count,
      "Step \(identifier) must verify every manifest claim exactly once."
    )
    for (index, verification) in verifications.enumerated() {
      guard index < manifestStep.claims.count else { return }
      XCTAssertEqual(
        verification.spec,
        manifestStep.claims[index].text,
        "Step \(identifier) assertion \(index + 1) must match claims.json."
      )
      XCTAssertTrue(
        verification.check(),
        manifestStep.claims[index].text,
        file: #filePath,
        line: #line
      )
    }
    let filename = String(format: "%03d-%@.png", nextScreenshotIndex, identifier)
    nextScreenshotIndex += 1
    let screenshot = screenshotElement?.screenshot() ?? XCUIScreen.main.screenshot()
    let attachment: XCTAttachment
    if let image = screenshot.image.cgImage,
       let cropped = crop(image, for: screenshotCrop)
    {
      attachment = XCTAttachment(image: UIImage(cgImage: cropped))
    } else {
      attachment = XCTAttachment(screenshot: screenshot)
    }
    attachment.name = filename
    attachment.lifetime = .keepAlways
    testCase.add(attachment)
  }

  private func crop(
    _ image: CGImage,
    for crop: WalkthroughScreenshotCrop
  ) -> CGImage? {
    switch crop {
    case .none:
      return nil
    case .systemAppIconInterior:
      // The Simulator renders a subtly nondeterministic Home Screen wallpaper.
      // Preserve only pixels inside MediNag's system-rendered icon, while the
      // step assertion independently proves that this icon is on SpringBoard.
      let rect = CGRect(x: 950, y: 580, width: 150, height: 150)
      guard image.width >= Int(rect.maxX), image.height >= Int(rect.maxY) else {
        return nil
      }
      return image.cropping(to: rect)
    case .systemAlarmWithoutAnimatedGlyph:
      // Preserve the real expanded AlarmKit title and system close control,
      // but exclude Apple's animated clock-and-bells glyph and unrelated Home
      // Screen pixels. Cropping avoids replacing any system pixels with
      // test-authored content.
      let left = 265
      let edge = 30
      let height = 230
      guard image.width > left + edge, image.height > edge + height else { return nil }
      return image.cropping(
        to: CGRect(
          x: left,
          y: edge,
          width: image.width - left - edge,
          height: height
        )
      )
    }
  }

}

private struct ClaimsManifest: Decodable {
  let storyId: String
  let steps: [ClaimStep]
}

private struct ClaimStep: Decodable {
  let id: String
  let surface: String
  let description: String
  let claims: [Claim]
}

private struct Claim: Decodable {
  let text: String
}
