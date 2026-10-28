import Foundation
import MediNagCore
import XCTest

final class CompanionModelsTests: XCTestCase {
  func testResponseVersionRejectsDuplicateSnoozesButNotTimestampRounding() {
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    var event = MedicationEvent(id: "unit-event", scheduleID: "unit-schedule", medicationName: "Unit dose",
                                scheduledTime: date, status: .snoozed, snoozeCount: 1, lastSnoozedAt: date)
    var copy = event
    copy.lastSnoozedAt = date.addingTimeInterval(0.0000002)
    XCTAssertTrue(event.hasSameResponseVersion(as: copy))
    copy.snoozeCount = 2
    XCTAssertFalse(event.hasSameResponseVersion(as: copy))
    copy = event
    copy.status = .completed
    XCTAssertFalse(event.hasSameResponseVersion(as: copy))
    event.status = .completed
    XCTAssertTrue(event.hasSameResponseVersion(as: copy))
    copy = event
    copy = MedicationEvent(id: "other-event", scheduleID: copy.scheduleID, medicationName: copy.medicationName,
                            scheduledTime: date, status: .completed, snoozeCount: 1)
    XCTAssertFalse(event.hasSameResponseVersion(as: copy))
  }

  func testWatchResponseWindowIsStrictlyLessThanFifteenMinutes() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var event = MedicationEvent(id: "unit-event", scheduleID: "unit-schedule", medicationName: "Unit test dose",
                                timeZone: "America/Toronto", scheduledTime: now.addingTimeInterval(60), status: .pending, snoozeCount: 0)
    func snapshot() -> CompanionSnapshot {
      CompanionSnapshot(patientID: "unit-patient", administratorID: "unit-admin", administratorName: "Unit admin",
                         planName: "Unit plan", events: [event], snoozeMinutes: 15, maximumReminderCount: 3,
                         ready: true, readinessMessage: "", logicalDate: now, realDate: now)
    }
    XCTAssertTrue(snapshot().canRespond(to: event, at: now))
    XCTAssertFalse(snapshot().canRespond(to: event, at: now.addingTimeInterval(-840)))
    XCTAssertTrue(snapshot().canRespond(to: event, at: now.addingTimeInterval(-839)))
    XCTAssertTrue(snapshot().canRespond(to: event, at: now.addingTimeInterval(60)))
    event.status = .snoozed
    event.snoozeCount = 1
    event.lastSnoozedAt = now
    XCTAssertFalse(snapshot().canRespond(to: event, at: now))
    XCTAssertTrue(snapshot().canRespond(to: event, at: now.addingTimeInterval(1)))
    XCTAssertTrue(snapshot().canRespond(to: event, at: now.addingTimeInterval(899)))
    XCTAssertTrue(snapshot().canRespond(to: event, at: now.addingTimeInterval(900)))
    event.status = .completed
    XCTAssertFalse(snapshot().canRespond(to: event, at: now.addingTimeInterval(3600)))
    let restored = try JSONDecoder().decode(CompanionSnapshot.self, from: JSONEncoder().encode(snapshot()))
    XCTAssertEqual(restored.events, [event])
    XCTAssertEqual(restored.snoozeMinutes, 15)
  }
}
