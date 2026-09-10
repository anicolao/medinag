import MediNagCore
import XCTest

final class MedicationModelsTests: XCTestCase {
  func testDoseResponseIdentifiersRemainStableForNotificationRouting() {
    XCTAssertEqual(DoseResponse.yesIWill.rawValue, "yesIWill")
    XCTAssertEqual(DoseResponse.yesIDid.rawValue, "yesIDid")
  }
}
