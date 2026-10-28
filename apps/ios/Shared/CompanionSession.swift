import Combine
import Foundation
import MediNagCore
@preconcurrency import WatchConnectivity
@preconcurrency import UserNotifications
#if os(watchOS)
  import WatchKit
#endif

@MainActor
final class CompanionSession: NSObject, ObservableObject, WCSessionDelegate {
  @Published private(set) var snapshot: CompanionSnapshot?
  @Published private(set) var reachable = false
  @Published private(set) var busy = false
  @Published private(set) var notice = ""
  @Published private(set) var hasPendingResponse = false
  var handleCommand: ((CompanionCommand) async -> CompanionReply)?
  var reportFailure: ((String) async -> Void)?
  private let session: WCSession?
  private var latestSnapshot: CompanionSnapshot?
  #if os(watchOS)
    private let notifications = DeviceReminderNotifications()
    private var notificationWork: Task<Void, Never>?
    private var contentObservation: NSKeyValueObservation?
    private var backgroundWaiters: [CheckedContinuation<Void, Never>] = []
    private var pendingResponse: CompanionCommand? {
      didSet {
        hasPendingResponse = pendingResponse != nil
        UserDefaults.standard.set(try? pendingResponse.map { try JSONEncoder().encode($0) },
                                  forKey: "medinag.watch.pending-response")
      }
    }
  #endif

  override init() {
    session = WCSession.isSupported() ? .default : nil
    super.init()
    #if os(watchOS)
      MediNagNotification.register()
      UNUserNotificationCenter.current().delegate = self
      if let data = UserDefaults.standard.data(forKey: "medinag.watch.snapshot"),
         let value = try? JSONDecoder().decode(CompanionSnapshot.self, from: data) { snapshot = value }
      if let data = UserDefaults.standard.data(forKey: "medinag.watch.pending-response") {
        pendingResponse = try? JSONDecoder().decode(CompanionCommand.self, from: data)
        hasPendingResponse = pendingResponse != nil
      }
    #endif
    session?.delegate = self
    session?.activate()
    #if os(watchOS)
      contentObservation = session?.observe(\.hasContentPending, options: [.new]) { @Sendable _, _ in
        Task { @MainActor [weak self] in self?.completeDrainedTransfers() }
      }
    #endif
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
    #if os(watchOS)
      if let pendingResponse { await exchange(pendingResponse); return }
    #endif
    await refresh()
    #if os(watchOS)
      await reconcileWatchNotifications(requestPermission: true)
    #endif
  }

  func respond(_ response: DoseResponse, to event: MedicationEvent) async {
    guard let snapshot else { return }
    let command = CompanionCommand(snapshot: snapshot, event: event, response: response)
    #if os(watchOS)
      guard !hasPendingResponse else { return }
      pendingResponse = command
      // Guaranteed background transfer complements interactive delivery. The
      // Firestore response-version transaction makes duplicate delivery safe.
      if let data = try? JSONEncoder().encode(command) { session?.transferUserInfo(["command": data]) }
    #endif
    await exchange(command)
  }

  private func exchange(_ command: CompanionCommand) async {
    guard !busy else { return }
    guard let session, session.activationState == .activated, session.isReachable else {
      reachable = false
      notice = command.response == nil ? "iPhone disconnected" : "Waiting for iPhone confirmation. Reminders remain active."
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
      #if os(watchOS)
        if command.response != nil, reply.accepted { pendingResponse = nil }
      #endif
      if command.response != nil || initialConnection || !reply.accepted {
        notice = reply.accepted ? "" : reply.message
      }
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
        completeDrainedTransfers()
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
    #if os(watchOS)
      UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: "medinag.watch.snapshot")
      if let pending = pendingResponse,
         pending.patientID != value.patientID || pending.administratorID != value.administratorID
          || !value.events.contains(where: { $0.id == pending.event?.id && $0.hasSameResponseVersion(as: pending.event!) }) {
        pendingResponse = nil
        notice = ""
      }
      notificationWork = Task { await reconcileWatchNotifications() }
    #endif
  }

  nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
    if let failure = userInfo["watchNotificationFailure"] as? String {
      Task { @MainActor in await reportFailure?(failure) }
      return
    }
    guard let data = userInfo["command"] as? Data,
          let command = try? JSONDecoder().decode(CompanionCommand.self, from: data) else { return }
    Task { @MainActor in
      guard let handleCommand else { return }
      let reply = await handleCommand(command)
      publish(reply.snapshot)
    }
  }

  #if os(watchOS)
    /// Keep the system's background execution assertion until WCSession has
    /// actually delivered its content and the OS notification queue is updated.
    func finishBackgroundTransfers() async {
      guard let session else { return }
      if session.activationState != .activated || session.hasContentPending {
        await withCheckedContinuation { backgroundWaiters.append($0) }
      }
      await notificationWork?.value
    }

    private func completeDrainedTransfers() {
      guard let session, session.activationState == .activated, !session.hasContentPending else { return }
      let waiting = backgroundWaiters
      backgroundWaiters.removeAll()
      waiting.forEach { $0.resume() }
    }

    private func reconcileWatchNotifications(requestPermission: Bool = false) async {
      do {
        guard let snapshot else { return }
        if !snapshot.ready {
          _ = try await notifications.reconcile(events: [], snoozeInterval: 600, logicalNow: Date())
          return
        }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if requestPermission && WKExtension.shared().applicationState == .active
          && settings.authorizationStatus == .notDetermined {
          _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
        let authorized = await center.notificationSettings().authorizationStatus
        guard authorized == .authorized || authorized == .provisional else {
          notice = "Allow MediNag notifications in Watch Settings."
          if authorized == .denied {
            session?.transferUserInfo(["watchNotificationFailure": "Watch medication notifications are disabled."])
          }
          return
        }
        let now = snapshot.logicalDate.addingTimeInterval(Date().timeIntervalSince(snapshot.realDate) / snapshot.clockScale)
        _ = try await notifications.reconcile(events: snapshot.events,
          snoozeInterval: Double(snapshot.snoozeMinutes * 60), logicalNow: now,
          clockScale: snapshot.clockScale, snapshot: snapshot)
      } catch is CancellationError {
        // A newer snapshot superseded this queue reconciliation.
      } catch {
        notice = "Watch reminders failed. Open MediNag on iPhone."
        session?.transferUserInfo(["watchNotificationFailure": error.localizedDescription])
      }
    }
  #endif

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

#if os(watchOS)
extension CompanionSession: UNUserNotificationCenterDelegate {
  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    completionHandler([.banner, .list, .sound])
  }

  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
    let action = response.actionIdentifier
    let data = response.notification.request.content.userInfo[MediNagNotification.command] as? Data
    completionHandler()
    // A dismiss/default tap does not answer the dose or cancel its queue.
    guard let choice: DoseResponse = action == MediNagNotification.yesIDid ? .yesIDid
      : action == MediNagNotification.yesIWill ? .yesIWill : nil,
      let data, let command = try? JSONDecoder().decode(CompanionCommand.self, from: data),
      let event = command.event else { return }
    Task { @MainActor in
      guard let snapshot, command.patientID == snapshot.patientID,
        command.administratorID == snapshot.administratorID,
        snapshot.events.contains(where: { $0.hasSameResponseVersion(as: event) }) else {
        notice = "This dose changed. Check the current dose."
        return
      }
      await respond(choice, to: event)
    }
  }
}
#endif
