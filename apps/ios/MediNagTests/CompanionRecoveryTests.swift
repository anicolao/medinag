import Foundation
import MediNagCore
import WatchConnectivity
import XCTest
@testable import MediNag

final class CompanionRecoveryTests: XCTestCase {
  private func snapshot() -> CompanionSnapshot {
    CompanionSnapshot(patientID: "unit-patient", administratorID: "unit-admin", administratorName: "Unit admin",
      planName: "Unit plan", events: [], snoozeMinutes: 10, maximumReminderCount: 3,
      ready: true, readinessMessage: "", logicalDate: Date(), realDate: Date())
  }

  func testMatchingBackgroundRejectionAndAcceptanceResolvePendingButBusyDoesNot() throws {
    let state = snapshot()
    let command = CompanionCommand(snapshot: state, response: .yesIDid)
    let other = CompanionCommand(snapshot: state, response: .yesIDid)
    let rejected = CompanionReply(snapshot: state, accepted: false, message: "Dose expired").acknowledging(command)
    XCTAssertTrue(rejected.resolves(command))
    XCTAssertFalse(rejected.resolves(other), "A delayed old acknowledgement cannot clear a new command")
    let busy = CompanionReply(snapshot: state, accepted: false, message: "Saving another dose", retryable: true).acknowledging(command)
    XCTAssertFalse(busy.resolves(command))
    let accepted = CompanionReply(snapshot: state, accepted: true, message: "Saved").acknowledging(command)
    XCTAssertTrue(accepted.resolves(command))
    let restored = try JSONDecoder().decode(CompanionReply.self, from: JSONEncoder().encode(rejected))
    XCTAssertTrue(restored.resolves(command))
    let restoredCommand = try JSONDecoder().decode(CompanionCommand.self, from: JSONEncoder().encode(command))
    XCTAssertEqual(restoredCommand.identifier, command.identifier)
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
