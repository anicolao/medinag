import Foundation
import MediNagCore
import XCTest

final class CompanionModelsTests: XCTestCase {
  func testPhoneRestartCannotEraseIndependentWatchRemindersButUnlinkCan() throws {
    let now = Date()
    func snapshot(ready: Bool, cleared: Bool = false, date: Date) -> CompanionSnapshot {
      CompanionSnapshot(patientID: ready ? "unit-patient" : nil,
        administratorID: ready ? "unit-admin" : nil, administratorName: "Unit admin",
        planName: "Unit plan", events: [], snoozeMinutes: 10, maximumReminderCount: 3,
        ready: ready, readinessMessage: "", logicalDate: date, realDate: date,
        scheduleCleared: cleared)
    }
    let cached = snapshot(ready: true, date: now)
    XCTAssertFalse(snapshot(ready: false, date: now.addingTimeInterval(1)).canReplace(cached))
    XCTAssertTrue(snapshot(ready: false, cleared: true, date: now.addingTimeInterval(1)).canReplace(cached))
    XCTAssertTrue(snapshot(ready: true, date: now.addingTimeInterval(1)).canReplace(cached))
    XCTAssertFalse(snapshot(ready: true, date: now.addingTimeInterval(-1)).canReplace(cached))
    // Older saved snapshots decode without the newly introduced optional flag.
    let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(cached)) as! [String: Any]
    let older = encoded.filter { $0.key != "scheduleCleared" }
    let restored = try JSONDecoder().decode(CompanionSnapshot.self, from: JSONSerialization.data(withJSONObject: older))
    XCTAssertNil(restored.scheduleCleared)
    XCTAssertTrue(restored.ready)
  }
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
