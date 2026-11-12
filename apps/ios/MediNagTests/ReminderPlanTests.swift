import Foundation
import MediNagCore
import XCTest
import UserNotifications
@testable import MediNag

final class ReminderPlanTests: XCTestCase {
  func testDeliveredOrDueRequestsAreNotMisreportedAsMissingFutureRequests() {
    let date = Date()
    let deadlines = Dictionary(uniqueKeysWithValues: (0..<60).map {
      ("unit-request-\($0)", date.addingTimeInterval($0 < 14 ? -1 : 600))
    })
    let pending = Set((14..<60).map { "unit-request-\($0)" })
    let verified = ReminderInventory(deadlines: deadlines, pending: pending, at: date)
    XCTAssertTrue(verified.complete)
    XCTAssertEqual(verified.expected.count, 46)
    XCTAssertEqual(verified.actual.count, 46, "Never claim the fourteen elapsed alerts are still pending or prove delivery")
    let missing = ReminderInventory(deadlines: deadlines, pending: pending.subtracting(["unit-request-59"]), at: date)
    XCTAssertFalse(missing.complete, "A genuinely missing future alert must still fail")
    XCTAssertEqual(missing.actual.count, 45)
  }
  private let now = Date(timeIntervalSince1970: 1_800_000_000)
  private func event(_ id: String, after: TimeInterval = 60) -> MedicationEvent {
    MedicationEvent(id: id, scheduleID: "unit-schedule", medicationName: "Unit dose",
      scheduledTime: now.addingTimeInterval(after), status: .pending, snoozeCount: 0)
  }

  func testDueRequestStillPendingInOSIsNotCancelledByRefreshAcrossDeadline() {
    let dose = event("initial", after: 0)
    XCTAssertTrue(ReminderPlan.retainsInFlight(dose, deadline: now, among: [dose],
      now: now.addingTimeInterval(0.2), snoozeInterval: 600))
    XCTAssertTrue(ReminderPlan.retainsInFlight(dose, deadline: now.addingTimeInterval(180), among: [dose],
      now: now.addingTimeInterval(180), snoozeInterval: 600), "Keep the actual OS request at an exact repeat boundary too")
    XCTAssertFalse(ReminderPlan.retainsInFlight(dose, deadline: now.addingTimeInterval(180), among: [dose],
      now: now.addingTimeInterval(0.2), snoozeInterval: 600), "Future obsolete requests are not in flight")
    var completed = dose; completed.status = .completed
    XCTAssertFalse(ReminderPlan.retainsInFlight(dose, deadline: now, among: [completed],
      now: now.addingTimeInterval(0.2), snoozeInterval: 600), "An answer must still cancel an in-flight request")
  }

  func testInFlightRetentionDoesNotSurviveSnoozeOrNewerDose() {
    let dose = event("initial", after: 0)
    var snoozed = dose; snoozed.status = .snoozed; snoozed.snoozeCount = 1
    snoozed.snoozedUntil = now.addingTimeInterval(600)
    XCTAssertFalse(ReminderPlan.retainsInFlight(dose, deadline: now, among: [snoozed],
      now: now.addingTimeInterval(180), snoozeInterval: 600))
    let next = event("next", after: 60)
    XCTAssertFalse(ReminderPlan.retainsInFlight(dose, deadline: now, among: [dose, next],
      now: now.addingTimeInterval(60), snoozeInterval: 600))
  }

  func testIgnoredCurrentDoseCannotStarveNextDoseWindow() throws {
    let first = event("first")
    let later = event("later", after: 86400)
    let plan = ReminderPlan(events: [first, later], now: now, snoozeInterval: 600)
    XCTAssertEqual(plan.occurrences.count, 22)
    XCTAssertTrue(plan.requiredPairCovered)
    for dose in [first, later] {
      XCTAssertEqual(plan.occurrences.filter { $0.event.id == dose.id }.map(\.date),
        (0...10).map { dose.scheduledTime.addingTimeInterval(Double($0 * 180)) })
    }
    XCTAssertEqual(plan.coveredThrough, later.scheduledTime.addingTimeInterval(1800))
  }

  func testTwoFullWindowsAreProtectedBeforeFurtherDosesAndNoPartialFutureWindowIsPromised() {
    let doses = (0..<8).map { event("dose-\($0)", after: Double($0 * 14400 + 60)) }
    let plan = ReminderPlan(events: doses, now: now, snoozeInterval: 600)
    XCTAssertEqual(plan.occurrences.count, 55)
    XCTAssertEqual(plan.protectedEventIDs.count, 5)
    XCTAssertTrue(plan.requiredPairCovered)
    XCTAssertEqual(plan.coveredThrough, doses[5].scheduledTime.addingTimeInterval(-1))
  }

  func testOneMinuteConfigurationCannotClaimTwoThirtyMinuteWindowsFit() {
    let first = event("first")
    let later = event("later", after: 14400)
    let plan = ReminderPlan(events: [first, later], now: now, snoozeInterval: 600, repeatInterval: 60)
    XCTAssertFalse(plan.requiredPairCovered)
    XCTAssertEqual(plan.requiredPairRequestCount, 62)
    XCTAssertEqual(plan.occurrences.count, 60)
    XCTAssertTrue(plan.occurrences.contains { $0.event.id == first.id && $0.attempt == 0 })
    XCTAssertTrue(plan.occurrences.contains { $0.event.id == later.id && $0.attempt == 0 })
  }

  func testExpiredWindowIsNotExtendedOnRefreshButNextDoseRemainsProtected() {
    let first = event("first", after: 0)
    let later = event("later", after: 14400)
    let plan = ReminderPlan(events: [first, later], now: now.addingTimeInterval(1801), snoozeInterval: 600)
    XCTAssertFalse(plan.occurrences.contains { $0.event.id == first.id })
    XCTAssertEqual(plan.occurrences.filter { $0.event.id == later.id }.count, 11)
  }

  func testNewDoseCutsOffEveryOlderRequestEvenInsideThirtyMinutes() {
    let first = event("first", after: 0)
    let later = event("later", after: 600)
    let plan = ReminderPlan(events: [first, later], now: now, snoozeInterval: 600)
    XCTAssertEqual(plan.occurrences.filter { $0.event.id == first.id }.map(\.date),
      [0, 180, 360, 540].map { now.addingTimeInterval(Double($0)) })
    XCTAssertEqual(plan.occurrences.filter { $0.event.id == later.id }.count, 11)
    XCTAssertTrue(plan.requiredPairCovered)
  }

  func testSnoozeRetainsAnchoredExpiryAndDoesNotRestartThirtyMinuteWindow() {
    var dose = event("dose", after: 0)
    dose.status = .snoozed
    dose.lastSnoozedAt = now.addingTimeInterval(720)
    dose.snoozedUntil = now.addingTimeInterval(1200)
    dose.snoozeCount = 1
    let plan = ReminderPlan(events: [dose], now: now.addingTimeInterval(720), snoozeInterval: 600)
    XCTAssertEqual(plan.occurrences.map(\.date), [1200, 1380, 1560, 1740].map { now.addingTimeInterval(Double($0)) })
    dose.snoozedUntil = now.addingTimeInterval(2400)
    let late = ReminderPlan(events: [dose], now: now.addingTimeInterval(1801), snoozeInterval: 600)
    XCTAssertEqual(late.occurrences.map(\.date), [now.addingTimeInterval(2400)], "Keep an explicitly requested expiry, without an unbounded new repeat window")
  }

  func testPreferredRefreshIsEarlyAndRespondsToDoseAndCoverageBoundaries() {
    XCTAssertEqual(ReminderRefreshPolicy.preferredDate(now: now, events: []), now.addingTimeInterval(900))
    XCTAssertEqual(ReminderRefreshPolicy.preferredDate(now: now, events: [event("soon", after: 600)]), now.addingTimeInterval(300))
    XCTAssertEqual(ReminderRefreshPolicy.preferredDate(now: now, events: [], coveredThrough: now.addingTimeInterval(1000)), now.addingTimeInterval(100))
    XCTAssertEqual(ReminderRefreshPolicy.preferredDate(now: now, events: [event("imminent", after: 60)]), now.addingTimeInterval(1))
  }

  func testMoreInitialDosesThanCapacityDoesNotOverpromiseCoverage() {
    let events = (1...70).map { event("dose-\($0)", after: Double($0 * 60)) }
    let plan = ReminderPlan(events: events, now: now, snoozeInterval: 600)
    XCTAssertEqual(plan.occurrences.count, 60)
    XCTAssertEqual(plan.coveredThrough, now.addingTimeInterval(3659))
    XCTAssertEqual(Set(plan.occurrences.map(\.identifier)).count, 60)
  }

  func testDismissalDoesNotAnswerOrResetThePlan() {
    let dose = event("dose")
    let before = ReminderPlan(events: [dose], now: now, snoozeInterval: 600, capacity: 4)
    let after = ReminderPlan(events: [dose], now: dose.scheduledTime.addingTimeInterval(1), snoozeInterval: 600, capacity: 4)
    XCTAssertEqual(after.occurrences.first?.date, dose.scheduledTime.addingTimeInterval(180))
    XCTAssertEqual(after.occurrences.first?.identifier, before.occurrences[1].identifier)
    XCTAssertNil(NotificationInteraction(actionIdentifier: UNNotificationDismissActionIdentifier, userInfo: [:]))
  }

  func testRealNotificationCategoriesExposeBothEqualActions() async throws {
    let center = UNUserNotificationCenter.current()
    MediNagNotification.register()
    let categories = await center.notificationCategories()
    let category = try XCTUnwrap(categories.first { $0.identifier == MediNagNotification.category })
    XCTAssertEqual(category.actions.map(\.title), ["Yes, I did", "Yes, I will"])
    XCTAssertEqual(category.actions[0].options, category.actions[1].options)
    XCTAssertNil(NotificationInteraction(actionIdentifier: UNNotificationDismissActionIdentifier, userInfo: [:]))
  }
}
