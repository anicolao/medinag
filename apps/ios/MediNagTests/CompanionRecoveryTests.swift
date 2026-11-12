import Foundation
import MediNagCore
import WatchConnectivity
import XCTest
import UserNotifications
@testable import MediNag

final class CompanionRecoveryTests: XCTestCase {
  private func snapshot() -> CompanionSnapshot {
    let event = MedicationEvent(id: "unit-event", scheduleID: "unit-schedule", medicationName: "Unit dose",
      scheduledTime: Date(timeIntervalSince1970: 1_800_000_000), status: .pending, snoozeCount: 0)
    return CompanionSnapshot(patientID: "unit-patient", administratorID: "unit-admin", administratorName: "Unit admin",
      planName: "Unit plan", events: [event], snoozeMinutes: 10, maximumReminderCount: 3,
      ready: true, readinessMessage: "", logicalDate: Date(), realDate: Date())
  }

  func testMatchingBackgroundRejectionAndAcceptanceResolvePendingButBusyDoesNot() throws {
    let state = snapshot()
    let command = CompanionCommand(snapshot: state, event: state.events[0], response: .yesIDid)
    let other = CompanionCommand(snapshot: state, event: state.events[0], response: .yesIDid)
    let rejected = CompanionReply(snapshot: state, accepted: false, message: "Dose expired").acknowledging(command)
    XCTAssertTrue(rejected.resolves(command))
    XCTAssertFalse(rejected.resolves(other), "A delayed old acknowledgement cannot clear a new command")
    let busy = CompanionReply(snapshot: state, accepted: false, message: "Saving another dose", retryable: true).acknowledging(command)
    XCTAssertFalse(busy.resolves(command))
    let accepted = CompanionReply(snapshot: state, accepted: true, message: "Saved").acknowledging(command)
    XCTAssertFalse(accepted.resolves(command), "A receipt ACK with an unanswered snapshot must not erase the local answer")
    var completed = state.events[0]; completed.status = .completed
    XCTAssertTrue(CompanionReply(snapshot: state.replacingEvents([completed]), accepted: true,
      message: "Saved").acknowledging(command).resolves(command))
    let restored = try JSONDecoder().decode(CompanionReply.self, from: JSONEncoder().encode(rejected))
    XCTAssertTrue(restored.resolves(command))
    let restoredCommand = try JSONDecoder().decode(CompanionCommand.self, from: JSONEncoder().encode(command))
    XCTAssertEqual(restoredCommand.identifier, command.identifier)
  }

  func testCompletedDoseCannotBeReinstalledByNewerTimestampWithOldResponseState() throws {
    let original = snapshot()
    var completed = original.events[0]; completed.status = .completed
    let protected = original.replacingEvents([completed])
    let incoming = CompanionSnapshot(patientID: original.patientID, administratorID: original.administratorID,
      administratorName: "Unit admin", planName: "Unit plan", events: original.events,
      snoozeMinutes: 10, maximumReminderCount: 3, ready: true, readinessMessage: "",
      logicalDate: original.logicalDate.addingTimeInterval(10), realDate: original.realDate.addingTimeInterval(10))
    XCTAssertTrue(incoming.canReplace(protected), "Transport time alone would allow this stale response")
    let restored = try JSONDecoder().decode(CompanionSnapshot.self, from: JSONEncoder().encode(protected))
    let merged = incoming.preservingResponseProgress(from: restored)
    XCTAssertEqual(merged.events[0].status, .completed)
    XCTAssertTrue(ReminderPlan(events: merged.events, now: original.events[0].scheduledTime,
      snoozeInterval: 600).occurrences.isEmpty, "Production planner must not re-register 1:15/1:27 after completion")
  }

  func testSnoozeProgressCannotBeUndoneButLaterSnoozeAndNewOccurrenceAreAccepted() {
    let original = snapshot()
    var snoozed = original.events[0]
    snoozed.status = .snoozed; snoozed.snoozeCount = 1
    snoozed.snoozedUntil = snoozed.scheduledTime.addingTimeInterval(600)
    let merged = original.preservingResponseProgress(from: original.replacingEvents([snoozed]))
    XCTAssertEqual(merged.events[0].snoozeCount, 1)
    XCTAssertEqual(ReminderPlan(events: merged.events, now: snoozed.scheduledTime.addingTimeInterval(180),
      snoozeInterval: 600).occurrences.first?.date, snoozed.snoozedUntil)
    var later = snoozed; later.snoozeCount = 2
    XCTAssertEqual(later.preservingResponseProgress(from: snoozed).snoozeCount, 2)
    let new = MedicationEvent(id: snoozed.id, scheduleID: snoozed.scheduleID, medicationName: snoozed.medicationName,
      scheduledTime: snoozed.scheduledTime.addingTimeInterval(86400), status: .pending, snoozeCount: 0)
    XCTAssertEqual(new.preservingResponseProgress(from: snoozed).status, .pending)
  }

  func testPhoneRefreshPolicyAlsoPreservesAnsweredStateAfterOutboxAcknowledgement() {
    let original = snapshot().events[0]
    var completed = original; completed.status = .completed
    let refreshed = AlertTiming.applyingPolicy(to: [original], previous: [completed],
      at: original.scheduledTime.addingTimeInterval(180), snoozeInterval: 600, repeatInterval: 180)
    XCTAssertEqual(refreshed[0].status, .completed)
    XCTAssertTrue(ReminderPlan(events: refreshed, now: original.scheduledTime.addingTimeInterval(180),
      snoozeInterval: 600).occurrences.isEmpty)
  }

  func testCompletionRemainsPendingWhenPhoneHasNotReceivedEarlierSnooze() {
    let raw = snapshot()
    var snoozed = raw.events[0]; snoozed.status = .snoozed; snoozed.snoozeCount = 1
    let command = CompanionCommand(snapshot: raw, event: snoozed, response: .yesIDid)
    XCTAssertTrue(command.remainsPending(in: raw, at: raw.events[0].scheduledTime.addingTimeInterval(180)),
      "An out-of-order older phone snapshot must not discard the later completion")
    var completed = snoozed; completed.status = .completed
    XCTAssertFalse(command.remainsPending(in: raw.replacingEvents([completed]), at: raw.events[0].scheduledTime))
  }

  func testAcknowledgedCompletionSurvivesFreshQueueOwnerAndOlderRefreshData() throws {
    let name = "unit-response-progress-\(UUID().uuidString).json"
    let file = try DurableAlertStorage.directory().appendingPathComponent(name)
    defer { try? FileManager.default.removeItem(at: file) }
    let original = snapshot().events[0]
    var completed = original; completed.status = .completed
    _ = try NotificationResponseProgress(storageName: name).protecting([completed])
    let afterRestart = try NotificationResponseProgress(storageName: name).protecting([original])
    XCTAssertEqual(afterRestart[0].status, .completed)
    XCTAssertTrue(ReminderPlan(events: afterRestart, now: original.scheduledTime.addingTimeInterval(180),
      snoozeInterval: 600).occurrences.isEmpty)
    XCTAssertTrue(try NotificationResponseProgress(storageName: name).protecting([]).isEmpty,
      "Stored responses must not invent occurrences absent from the actual schedule")
  }

  func testRealOSInventoryRejectsUnprotectedQueueAndCancelsWhenAuthorized() async throws {
    // Actual OS inventory, not delivery E2E proof. A fresh unit-test host has
    // not had a patient grant permission; do not fake that grant or call the
    // authorized cancellation branch tested when only this negative path ran.
    let now = Date()
    let dose = MedicationEvent(id: "unit-cancellation", scheduleID: "unit-schedule", medicationName: "Unit dose",
      scheduledTime: now.addingTimeInterval(600), status: .pending, snoozeCount: 0)
    let queue = DeviceReminderNotifications.shared
    let settings = await UNUserNotificationCenter.current().notificationSettings()
    if ![UNAuthorizationStatus.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) {
      do {
        _ = try await queue.reconcile(events: [dose], snoozeInterval: 600, logicalNow: now)
        XCTFail("A permission-less queue must not be reported as protected")
      } catch {
        XCTAssertEqual((error as NSError).domain, "MediNag.NotificationQueue")
        XCTAssertEqual((error as NSError).code, 1)
      }
      let attachment = XCTAttachment(string: "Exercised unauthorized real-OS inventory rejection, not authorized cancellation. The connected notification-action journey must verify cancellation after its real OS permission prompt.")
      attachment.lifetime = .keepAlways
      add(attachment)
      return
    }
    _ = try await queue.reconcile(events: [dose], snoozeInterval: 600, logicalNow: now)
    let installed = await UNUserNotificationCenter.current().pendingNotificationRequests()
    XCTAssertEqual(installed.filter { $0.identifier.hasPrefix("medinag.dose.unit-cancellation.") }.count, 11)
    var completed = dose; completed.status = .completed
    _ = try await queue.reconcile(events: [completed], snoozeInterval: 600, logicalNow: now)
    let cancelled = await UNUserNotificationCenter.current().pendingNotificationRequests()
    XCTAssertFalse(cancelled.contains { $0.identifier.hasPrefix("medinag.dose.unit-cancellation.") })
    let roundTrip = try JSONDecoder().decode(MedicationEvent.self, from: JSONEncoder().encode(completed))
    let refreshed = AlertTiming.applyingPolicy(to: [dose], previous: [roundTrip], at: now,
      snoozeInterval: 600, repeatInterval: 180)
    _ = try await queue.reconcile(events: refreshed, snoozeInterval: 600, logicalNow: now)
    let afterStaleRefresh = await UNUserNotificationCenter.current().pendingNotificationRequests()
    XCTAssertFalse(afterStaleRefresh.contains { $0.identifier.hasPrefix("medinag.dose.unit-cancellation.") })
  }

  func testNormalBackgroundUnreachabilityNeverTriggersImmediateAdministratorSMS() {
    let now = Date()
    let transient = NSError(domain: WCErrorDomain, code: 7007)
    var failures = CompanionTransportFailures()
    XCTAssertFalse(failures.record(transient, at: now))
    XCTAssertFalse(failures.record(transient, at: now.addingTimeInterval(100)))
    XCTAssertFalse(failures.record(transient, at: now.addingTimeInterval(299)))
    XCTAssertTrue(failures.record(transient, at: now.addingTimeInterval(300)), "Persistent actual transfer failures must still alert")
    XCTAssertFalse(failures.record(transient, at: now.addingTimeInterval(600)), "Do not spam duplicate alerts")
    failures.recovered()
    XCTAssertFalse(failures.record(transient, at: now.addingTimeInterval(601)))
  }

  func testInvalidPayloadIsARealFailureNotDismissedAsNormalBackgrounding() {
    var failures = CompanionTransportFailures()
    XCTAssertTrue(failures.record(NSError(domain: WCErrorDomain, code: 7009), at: Date()))
  }

  func testTimeoutAndLateReplyCannotResumeContinuationTwice() async throws {
    let data: Data = try await withCheckedThrowingContinuation { continuation in
      let reply = CompanionMessageReply(continuation)
      XCTAssertTrue(reply.finish(.success(Data([1]))))
      XCTAssertFalse(reply.finish(.failure(NSError(domain: WCErrorDomain, code: 7012))))
      XCTAssertFalse(reply.finish(.success(Data([2]))))
    }
    XCTAssertEqual(data, Data([1]))
    do {
      let _: Data = try await withCheckedThrowingContinuation { continuation in
        let reply = CompanionMessageReply(continuation)
        XCTAssertTrue(reply.finish(.failure(NSError(domain: WCErrorDomain, code: 7012))))
        XCTAssertFalse(reply.finish(.success(Data([3]))))
      }
      XCTFail("An expired operation must report failure, not success")
    } catch { XCTAssertEqual((error as NSError).code, 7012) }
  }
}
