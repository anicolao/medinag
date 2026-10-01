import MediNagCore
import XCTest
@testable import MediNag

final class MedicationModelsTests: XCTestCase {
  func testDoseResponseIdentifiersRemainStableForNotificationRouting() {
    XCTAssertEqual(DoseResponse.yesIWill.rawValue, "yesIWill")
    XCTAssertEqual(DoseResponse.yesIDid.rawValue, "yesIDid")
  }

  func testReminderTimeUsesPatientTimeZoneInsteadOfRunnerTimeZone() throws {
    let date = try XCTUnwrap(
      ISO8601DateFormatter().date(from: "2026-09-24T12:00:00Z")
    )

    let displayTime = MediNagDateFormatting.reminderTime(
      date,
      timeZoneIdentifier: "America/Toronto"
    ).replacingOccurrences(of: "\u{202f}", with: " ")

    XCTAssertEqual(displayTime, "8:00 AM")
  }
}
