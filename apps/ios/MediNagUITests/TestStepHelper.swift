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
    guard
      let url = Bundle(for: type(of: testCase)).url(
        forResource: "claims",
        withExtension: "json"
      ),
      let data = try? Data(contentsOf: url),
      let claims = try? JSONDecoder().decode(ClaimsManifest.self, from: data),
      claims.storyId == "US-004",
      storyID == "004-ios-respond-to-dose"
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
    trimAnimatedSystemEdge: Bool = false
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
