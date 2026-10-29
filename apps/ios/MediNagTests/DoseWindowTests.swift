import Foundation
import MediNagCore
import XCTest

final class DoseWindowTests: XCTestCase {
  private let ten = Date(timeIntervalSince1970: 1_800_000_000)
  private func event(_ id: String, offset: TimeInterval, status: MedicationEventStatus = .pending) -> MedicationEvent {
    MedicationEvent(id: id, scheduleID: id, medicationName: id, scheduledTime: ten.addingTimeInterval(offset),
      status: status, snoozeCount: 0)
  }

  func testNewDoseRetiresPreviousAcrossDifferentSchedulesAtExactBoundary() throws {
    let morning = event("ten-am", offset: 0)
    let noon = event("noon", offset: 7200)
    let history = [morning, noon]
    XCTAssertTrue(DoseWindow.isActive(morning, among: history, at: ten.addingTimeInterval(7199)))
    XCTAssertFalse(DoseWindow.isActive(morning, among: history, at: noon.scheduledTime))
    XCTAssertEqual(DoseWindow.nextEvent(in: history, at: noon.scheduledTime, snoozeInterval: 600)?.id, noon.id)
    let plan = ReminderPlan(events: history, now: ten.addingTimeInterval(-60), snoozeInterval: 600)
    XCTAssertFalse(plan.occurrences.contains { $0.event.id == morning.id && $0.date >= noon.scheduledTime })
    let restarted = ReminderPlan(events: history, now: noon.scheduledTime.addingTimeInterval(30), snoozeInterval: 600)
    XCTAssertFalse(restarted.occurrences.contains { $0.event.id == morning.id })
    XCTAssertEqual(morning.status, .pending, "Retirement is not a fabricated completion")
  }

  func testCompletedLaterDoseAndSimultaneousDoseGroups() {
    let morning = event("old", offset: 0)
    let sameTime = event("same-time", offset: 0)
    let noon = event("completed-noon", offset: 7200, status: .completed)
    XCTAssertTrue(DoseWindow.isActive(morning, among: [morning, sameTime], at: ten))
    XCTAssertTrue(DoseWindow.isActive(sameTime, among: [morning, sameTime], at: ten))
    XCTAssertFalse(DoseWindow.isActive(morning, among: [morning, noon], at: noon.scheduledTime))
    XCTAssertTrue(ReminderPlan(events: [morning, noon], now: noon.scheduledTime, snoozeInterval: 600).occurrences.isEmpty)
  }

  func testSnoozeCannotMoveAnOldDoseBeyondNextDose() {
    var morning = event("snoozed", offset: 0)
    morning.status = .snoozed
    morning.lastSnoozedAt = ten.addingTimeInterval(7100)
    let noon = event("noon", offset: 7200)
    let plan = ReminderPlan(events: [morning, noon], now: ten.addingTimeInterval(7100), snoozeInterval: 600)
    XCTAssertFalse(plan.occurrences.contains { $0.event.id == morning.id })
  }

  func testWatchSwitchesAtBoundaryWithoutAnotherPhoneSnapshotAndExpiresOldOutbox() {
    let morning = event("morning", offset: 0)
    let noon = event("noon", offset: 7200)
    let snapshot = CompanionSnapshot(patientID: "unit-patient", administratorID: "unit-admin",
      administratorName: "Unit admin", planName: "Unit plan", events: [morning, noon], snoozeMinutes: 10,
      maximumReminderCount: 3, ready: true, readinessMessage: "", logicalDate: ten, realDate: ten)
    let pending = CompanionCommand(snapshot: snapshot, event: morning, response: .yesIDid)
    XCTAssertTrue(pending.remainsPending(in: snapshot, at: ten))
    XCTAssertFalse(pending.remainsPending(in: snapshot, at: noon.scheduledTime))
    XCTAssertFalse(snapshot.canRespond(to: morning, at: noon.scheduledTime))
    XCTAssertEqual(snapshot.nextEvent(at: noon.scheduledTime)?.id, noon.id)
  }
}
