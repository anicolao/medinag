import Combine
import Foundation
import MediNagCore
@preconcurrency import WatchConnectivity

@MainActor
final class CompanionSession: NSObject, ObservableObject, WCSessionDelegate {
  @Published private(set) var snapshot: CompanionSnapshot?
  @Published private(set) var reachable = false
  @Published private(set) var busy = false
  @Published private(set) var notice = ""
  var handleCommand: ((CompanionCommand) async -> CompanionReply)?
  var reportFailure: ((String) async -> Void)?
  private let session: WCSession?
  private var latestSnapshot: CompanionSnapshot?

  override init() {
    session = WCSession.isSupported() ? .default : nil
    super.init()
    session?.delegate = self
    session?.activate()
  }

  func publish(_ value: CompanionSnapshot) {
    latestSnapshot = value
    guard let session, session.activationState == .activated else { return }
    #if os(iOS)
      guard session.isPaired, session.isWatchAppInstalled else { return }
    #endif
    do {
      try session.updateApplicationContext(["snapshot": JSONEncoder().encode(value)])
    } catch {
      notice = "Watch synchronization failed: \(error.localizedDescription)"
      if let reportFailure { Task { await reportFailure(error.localizedDescription) } }
    }
  }

  func refresh() async { await exchange(CompanionCommand()) }

  func refreshOnActivation() async {
    // Background context delivery is opportunistic. A newly installed Watch
    // must actively request the phone's current state even without a cache.
    await refresh()
  }

  func respond(_ response: DoseResponse, to event: MedicationEvent) async {
    guard let snapshot else { return }
    await exchange(CompanionCommand(snapshot: snapshot, event: event, response: response))
  }

  private func exchange(_ command: CompanionCommand) async {
    guard !busy else { return }
    guard let session, session.activationState == .activated, session.isReachable else {
      reachable = false
      notice = "iPhone unavailable. Reconnect and open MediNag on iPhone. No response has been recorded."
      return
    }
    busy = true
    let initialConnection = snapshot == nil
    if command.response != nil || initialConnection { notice = "Connecting to iPhone…" }
    defer { busy = false }
    do {
      let data = try JSONEncoder().encode(command)
      let response: Data = try await withCheckedThrowingContinuation { continuation in
        // WCSession invokes these blocks on its own operation queue. Explicit
        // Sendable closures must not inherit the view model's MainActor, or
        // Swift 6 traps when the real reply/error arrives off the main queue.
        session.sendMessageData(data,
          replyHandler: { @Sendable data in continuation.resume(returning: data) },
          errorHandler: { @Sendable error in continuation.resume(throwing: error) })
      }
      let reply = try JSONDecoder().decode(CompanionReply.self, from: response)
      apply(reply.snapshot)
      if command.response != nil || initialConnection || !reply.accepted { notice = reply.message }
      reachable = session.isReachable
    } catch {
      notice = command.response == nil
        ? "Could not refresh from iPhone. \(error.localizedDescription)"
        : "Could not confirm the response. Refresh before trying again. \(error.localizedDescription)"
    }
  }

  nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                           error: Error?) {
    let data = session.receivedApplicationContext["snapshot"] as? Data
    let connected = session.isReachable
    Task { @MainActor in
      reachable = connected
      if let data, let value = try? JSONDecoder().decode(CompanionSnapshot.self, from: data) { apply(value) }
      if let error { notice = error.localizedDescription }
      if let value = latestSnapshot { publish(value) }
      #if os(watchOS)
        if connected { await refreshOnActivation() }
      #endif
    }
  }

  nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
    let connected = session.isReachable
    Task { @MainActor in
      reachable = connected
      #if os(watchOS)
        if connected { await refreshOnActivation() }
      #endif
    }
  }

  nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
    guard let data = applicationContext["snapshot"] as? Data,
          let value = try? JSONDecoder().decode(CompanionSnapshot.self, from: data) else { return }
    Task { @MainActor in apply(value) }
  }

  private func apply(_ value: CompanionSnapshot) {
    // Background contexts and interactive replies use different delivery
    // channels. A delayed pre-response context must not undo an acknowledged
    // snooze/completion on the Watch.
    guard snapshot.map({ value.realDate >= $0.realDate }) ?? true else { return }
    if snapshot?.patientID != value.patientID || snapshot?.administratorID != value.administratorID {
      notice = ""
    }
    snapshot = value
  }

  private struct ReplySender: @unchecked Sendable { let send: (Data) -> Void }

  nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data,
                           replyHandler: @escaping (Data) -> Void) {
    let sender = ReplySender(send: replyHandler)
    guard let command = try? JSONDecoder().decode(CompanionCommand.self, from: messageData) else {
      sender.send(Data())
      return
    }
    Task { @MainActor in
      guard let handleCommand else { sender.send(Data()); return }
      let reply = await handleCommand(command)
      sender.send((try? JSONEncoder().encode(reply)) ?? Data())
    }
  }

  #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
      Task { @MainActor in if let value = latestSnapshot { publish(value) } }
    }
  #endif
}
