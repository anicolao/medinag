import Foundation
import MediNagCore
import XCTest
@testable import MediNag

/// Unit/integration checks, not proof of OS presentation or physical routing.
final class AlertTimingTests: XCTestCase {
  private let eight = Date(timeIntervalSince1970: 1_800_000_000)
  private func dose(_ id: String = "unit-dose", offset: Double = 0) -> MedicationEvent {
    MedicationEvent(id: id, scheduleID: "unit-schedule", medicationName: "Unit medication",
      scheduledTime: eight.addingTimeInterval(offset), status: .pending, snoozeCount: 0)
  }

  func testSnoozesUseOriginalTimeGridIncludingLateAndExactBoundaryTaps() {
    for (minutes, expected) in [(3.0, 10.0), (4.0, 10.0), (9.5, 10.0), (10.0, 20.0),
      (12.0, 20.0), (13.0, 20.0), (20.0, 30.0)] {
      XCTAssertEqual(AlertTiming.snoozeDeadline(for: dose(),
        respondedAt: eight.addingTimeInterval(minutes * 60), interval: 600),
        eight.addingTimeInterval(expected * 60))
    }
  }

  func testLateSnoozeCancelsIntermediateRepeatsAndStartsAtEightTwenty() {
    let response = LocalDoseResponse(patientID: "unit-patient", administratorID: "unit-admin",
      event: dose(), response: .yesIWill, respondedAt: eight.addingTimeInterval(720), snoozeInterval: 600)
    let plan = ReminderPlan(events: [response.updatedEvent], now: eight.addingTimeInterval(720),
      snoozeInterval: 600, repeatInterval: 180, capacity: 3)
    XCTAssertEqual(plan.occurrences.map(\.date), [1200.0, 1380, 1560].map { eight.addingTimeInterval($0) })
  }

  func testAdministratorRepeatAndSnoozeValuesAreNotHardcodedInPlanner() {
    let event = dose()
    XCTAssertEqual(AlertTiming.snoozeDeadline(for: event, respondedAt: eight.addingTimeInterval(180), interval: 420),
      eight.addingTimeInterval(420))
    let plan = ReminderPlan(events: [event], now: eight.addingTimeInterval(-1),
      snoozeInterval: 420, repeatInterval: 120, capacity: 3)
    XCTAssertEqual(plan.occurrences.map(\.date), [0.0, 120, 240].map { eight.addingTimeInterval($0) })
  }

  func testNextDoseEarlyCompletionAtInclusiveFifteenMinuteBoundary() {
    let next = dose(offset: 900)
    XCTAssertFalse(AlertTiming.canComplete(next, among: [next], at: eight.addingTimeInterval(-0.01), snoozeInterval: 600))
    XCTAssertTrue(AlertTiming.canComplete(next, among: [next], at: eight, snoozeInterval: 600))
    let completion = LocalDoseResponse(patientID: "unit-patient", administratorID: "unit-admin",
      event: next, response: .yesIDid, respondedAt: eight, snoozeInterval: 600)
    XCTAssertTrue(ReminderPlan(events: [completion.updatedEvent], now: eight, snoozeInterval: 600).occurrences.isEmpty)
  }

  func testCompletedNewestNeverRevealsEarlierUnansweredDose() {
    let old = dose("yesterday", offset: -86400)
    let current = dose("today")
    var completed = current; completed.status = .completed
    XCTAssertNil(DoseWindow.nextEvent(in: [old, completed], at: eight, snoozeInterval: 600))
    XCTAssertTrue(ReminderPlan(events: [old, completed], now: eight, snoozeInterval: 600).occurrences.isEmpty)
  }

  func testActiveDueAlertWinsOverFutureEarlyCompletion() {
    let old = dose("current")
    let next = dose("next", offset: 600)
    XCTAssertEqual(DoseWindow.nextEvent(in: [old, next], at: eight, snoozeInterval: 600)?.id, old.id)
  }

  func testCompletedFutureStillRetiresOldAlertOnlyAtItsDueTime() {
    let old = dose("current")
    var next = dose("next", offset: 600); next.status = .completed
    XCTAssertTrue(DoseWindow.isActive(old, among: [old, next], at: eight))
    XCTAssertFalse(DoseWindow.isActive(old, among: [old, next], at: next.scheduledTime))
  }

  @MainActor
  func testResponseSurvivesRealFileReloadAndRetainsItsOriginalDeadline() throws {
    let name = "unit-outbox-\(UUID().uuidString).json"
    let store = LocalResponseOutbox(storageName: name)
    let response = LocalDoseResponse(patientID: "unit-patient", administratorID: "unit-admin",
      event: dose(), response: .yesIWill, respondedAt: eight.addingTimeInterval(720), snoozeInterval: 600)
    try store.append(response)
    try store.append(response)
    let reloaded = LocalResponseOutbox(storageName: name)
    XCTAssertEqual(reloaded.responses.count, 1)
    XCTAssertEqual(reloaded.responses.first?.snoozeDeadline, eight.addingTimeInterval(1200))
    let events = reloaded.applying(to: [dose()], patientID: "unit-patient", administratorID: "unit-admin")
    XCTAssertEqual(events.first?.status, .snoozed)
    XCTAssertEqual(reloaded.applying(to: [dose()], patientID: "other-patient", administratorID: "unit-admin").first?.status, .pending)
    try reloaded.remove(response.id)
    XCTAssertTrue(LocalResponseOutbox(storageName: name).responses.isEmpty)
  }
}
