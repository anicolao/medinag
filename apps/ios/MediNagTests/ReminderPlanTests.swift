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

  func testFarFutureDosesCannotStarveCurrentFollowUps() throws {
    let first = event("first")
    let later = event("later", after: 86400)
    let plan = ReminderPlan(events: [first, later], now: now, snoozeInterval: 600, capacity: 4)
    XCTAssertEqual(plan.occurrences.count, 4)
    XCTAssertFalse(plan.occurrences.contains { $0.event.id == "later" })
    XCTAssertEqual(plan.coveredThrough, now.addingTimeInterval(779))
    XCTAssertLessThan(try XCTUnwrap(plan.coveredThrough), later.scheduledTime)
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
