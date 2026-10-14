import MediNagCore
import Dispatch
import UserNotifications
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

  @MainActor
  func testBackgroundRefreshHandlerUsesMainQueue() {
    XCTAssertTrue(AppDelegate.reminderRefreshQueue === DispatchQueue.main)
  }

  func testDeliveredMedicationNotificationBecomesAnOpenedInteraction() throws {
    let interaction = try XCTUnwrap(NotificationInteraction(
      actionIdentifier: UNNotificationDefaultActionIdentifier,
      userInfo: [
        MediNagNotification.eventID: "event-1",
        MediNagNotification.medicationName: "Morning medicine",
        MediNagNotification.reminderTime: 1_800_000_000.0,
        MediNagNotification.reminderNumber: 2,
        MediNagNotification.timeZone: "America/Toronto",
      ]
    ))

    guard case .opened = interaction.kind else {
      return XCTFail("A delivered reminder should request the response screen")
    }
    XCTAssertEqual(interaction.eventID, "event-1")
    XCTAssertEqual(interaction.medicationName, "Morning medicine")
    XCTAssertEqual(interaction.reminderTime.timeIntervalSince1970, 1_800_000_000)
    XCTAssertEqual(interaction.reminderNumber, 2)
    XCTAssertEqual(interaction.timeZoneIdentifier, "America/Toronto")
  }
}
