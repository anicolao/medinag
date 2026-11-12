import Foundation
@preconcurrency import WatchConnectivity

/// Instant-message reachability is not physical connectivity. Temporary
/// background/lifecycle failures are retried on the next real session signal.
struct CompanionTransportFailures {
  private(set) var firstFailure: Date?
  private(set) var attempts = 0
  private(set) var alerted = false

  static func isTransient(_ error: Error) -> Bool {
    let error = error as NSError
    guard error.domain == WCErrorDomain else { return false }
    return [WCError.Code.sessionNotActivated, .notReachable, .messageReplyFailed,
      .messageReplyTimedOut, .deliveryFailed, .sessionInactive, .transferTimedOut]
      .contains { $0.rawValue == error.code }
  }

  mutating func record(_ error: Error, at date: Date) -> Bool {
    if firstFailure == nil { firstFailure = date }
    attempts += 1
    guard !alerted else { return false }
    let persistent = attempts >= 3 && date.timeIntervalSince(firstFailure ?? date) >= 5 * 60
    guard !Self.isTransient(error) || persistent else { return false }
    alerted = true
    return true
  }

  mutating func recovered() { self = CompanionTransportFailures() }
}

/// A production operation deadline, not a test delay. A late WCSession callback
/// must never resume the checked continuation twice after the timeout wins.
final class CompanionMessageReply: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Data, Error>?
  private var deadline: DispatchWorkItem?
  init(_ continuation: CheckedContinuation<Data, Error>) { self.continuation = continuation }

  func armTimeout(after interval: TimeInterval) {
    let work = DispatchWorkItem { [weak self] in
      self?.finish(.failure(NSError(domain: WCErrorDomain, code: WCError.Code.messageReplyTimedOut.rawValue,
        userInfo: [NSLocalizedDescriptionKey: "iPhone confirmation timed out. The response remains queued."])))
    }
    lock.withLock { deadline = work }
    DispatchQueue.global().asyncAfter(deadline: .now() + interval, execute: work)
  }

  @discardableResult
  func finish(_ result: Result<Data, Error>) -> Bool {
    let (pending, timer) = lock.withLock {
      let value = continuation
      let timer = deadline
      continuation = nil
      deadline = nil
      return (value, timer)
    }
    timer?.cancel()
    pending?.resume(with: result)
    return pending != nil
  }
}
