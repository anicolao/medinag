import Combine
import Foundation
import MediNagCore
import OSLog
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
  @Published private(set) var responding = false
  var handleCommand: ((CompanionCommand) async -> CompanionReply)?
  var reportFailure: ((String) async -> Void)?
  var reportNotificationFailure: ((String) async -> Void)?
  private let session: WCSession?
  private var latestSnapshot: CompanionSnapshot?
  private var transportFailures = CompanionTransportFailures()
  private static let logger = Logger(subsystem: "org.boardgamescafe.medinag", category: "WatchConnectivity")

  var presentationSnapshot: CompanionSnapshot? {
    #if os(watchOS)
      guard let snapshot, let command = pendingResponse, let event = command.event,
        let response = command.response, let tap = command.respondedAt,
        command.patientID == snapshot.patientID, command.administratorID == snapshot.administratorID,
        let index = snapshot.events.firstIndex(where: { $0.hasSameOccurrence(as: event) })
      else { return snapshot }
      var events = snapshot.events
      let local = LocalDoseResponse(patientID: command.patientID ?? "",
        administratorID: command.administratorID ?? "", event: event, response: response,
        respondedAt: tap, snoozeInterval: Double(snapshot.snoozeMinutes * 60)).updatedEvent
      events[index] = events[index].preservingResponseProgress(from: local)
      return snapshot.replacingEvents(events)
    #else
      return snapshot
    #endif
  }
  #if os(watchOS)
    private let notifications = DeviceReminderNotifications.shared
    private var notificationWork: Task<Void, Never>?
    private var contentObservation: NSKeyValueObservation?
    private var backgroundWaiters: [CheckedContinuation<Void, Never>] = []
    private var activationWaiters: [UUID: CompanionMessageReply] = [:]
    private var pendingResponse: CompanionCommand? {
      didSet {
        hasPendingResponse = pendingResponse != nil
        UserDefaults.standard.set(try? pendingResponse.map { try JSONEncoder().encode($0) },
                                  forKey: "medinag.watch.pending-response")
        do { try DurableAlertStorage.save(pendingResponse, name: "watch-response.json") }
        catch { LocalAlertJournal.record("response_save_failed", details: ["error": error.localizedDescription]) }
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
      if let saved = try? DurableAlertStorage.load(CompanionCommand.self, name: "watch-response.json") {
        pendingResponse = saved
        hasPendingResponse = true
      } else if let data = UserDefaults.standard.data(forKey: "medinag.watch.pending-response") {
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
      transportFailures.recovered()
    } catch {
      Self.logger.error("Watch snapshot transfer failed: \(error.localizedDescription, privacy: .public)")
      if transportFailures.record(error, at: Date()), let reportFailure {
        let detail = "\((error as NSError).domain) (\((error as NSError).code)): \(error.localizedDescription)"
        Task { await reportFailure(detail) }
      }
    }
  }

  func refresh(timeout: TimeInterval = 5) async {
    let command = CompanionCommand()
    #if os(watchOS)
      if let session, session.activationState == .activated, !session.isReachable {
        let queued = session.outstandingUserInfoTransfers.contains {
          guard let data = $0.userInfo["command"] as? Data,
            let command = try? JSONDecoder().decode(CompanionCommand.self, from: data) else { return false }
          return command.response == nil
        }
        if !queued, let data = try? JSONEncoder().encode(command) {
          session.transferUserInfo(["command": data])
        }
      }
    #endif
    await exchange(command, timeout: timeout)
  }

  func refreshOnActivation() async {
    // Background context delivery is opportunistic. A newly installed Watch
    // must actively request the phone's current state even without a cache.
    #if os(watchOS)
      discardSupersededResponse()
    #endif
    await refresh()
    #if os(watchOS)
      await reconcileWatchNotifications(requestPermission: true)
      discardSupersededResponse()
      if let pendingResponse {
        queueResponse(pendingResponse)
        await exchange(pendingResponse)
      }
    #endif
  }

  func respond(_ response: DoseResponse, to event: MedicationEvent) async {
    guard let snapshot = presentationSnapshot else {
      LocalAlertJournal.record("response_rejected", eventID: event.id, details: ["reason": "missing_snapshot"])
      return
    }
    guard snapshot.canRespond(to: event) else {
      LocalAlertJournal.record("response_rejected", eventID: event.id,
        details: ["reason": "not_actionable", "status": event.status.rawValue, "snoozeCount": String(event.snoozeCount)])
      notice = "This reminder has been replaced or is not ready for a response."
      return
    }
    let command = CompanionCommand(snapshot: snapshot, event: event, response: response)
    #if os(watchOS)
      discardSupersededResponse()
      if let pending = pendingResponse {
        if pending.event?.hasSameResponseVersion(as: event) == true, pending.response == response {
          queueResponse(pending)
          await exchange(pending)
          return
        }
        // A later real choice (especially completion after a snooze) replaces
        // the local overlay. The earlier command is already OS-queued.
        queueResponse(pending)
      }
      do { try DurableAlertStorage.save(command, name: "watch-response.json") }
      catch {
        LocalAlertJournal.record("response_save_failed", eventID: event.id,
          details: ["error": error.localizedDescription])
        session?.transferUserInfo(["watchNotificationFailure": "Watch could not save the medication response."])
        return
      }
      pendingResponse = command
      LocalAlertJournal.record("response_saved_locally", eventID: event.id,
        deadline: response == .yesIWill ? AlertTiming.snoozeDeadline(for: event,
          respondedAt: command.respondedAt ?? Date(), interval: Double(snapshot.snoozeMinutes * 60)) : nil,
        details: ["action": response.rawValue, "commandID": command.identifier,
          "tappedAt": String((command.respondedAt ?? Date()).timeIntervalSince1970),
          "latencyFromDose": String((command.respondedAt ?? Date()).timeIntervalSince(event.scheduledTime))])
      // Apply and register the locally saved choice before waiting on phone or
      // Firebase. The raw received snapshot stays separate for reconciliation.
      await reconcileWatchNotifications()
      // OS-managed background transfer complements interactive delivery. The
      // Firestore response-version transaction makes duplicate delivery safe.
      await waitForActivationIfNeeded()
      queueResponse(command)
    #endif
    #if os(watchOS)
      Task { await exchange(command) }
    #else
      await exchange(command)
    #endif
  }

  private func exchange(_ command: CompanionCommand, timeout: TimeInterval = 5) async {
    guard !busy else { return }
    guard let session, session.activationState == .activated, session.isReachable else {
      reachable = false
      if command.response != nil {
        notice = "Response queued for iPhone. It has not been confirmed yet."
      }
      return
    }
    busy = true
    responding = command.response != nil
    let initialConnection = snapshot == nil
    if command.response != nil || initialConnection { notice = "Connecting to iPhone…" }
    defer { busy = false; responding = false }
    do {
      let data = try JSONEncoder().encode(command)
      let response: Data = try await withCheckedThrowingContinuation { continuation in
        // WCSession invokes these blocks on its own operation queue. Explicit
        // Sendable closures must not inherit the view model's MainActor, or
        // Swift 6 traps when the real reply/error arrives off the main queue.
        let reply = CompanionMessageReply(continuation)
        reply.armTimeout(after: timeout)
        session.sendMessageData(data,
          replyHandler: { @Sendable data in reply.finish(.success(data)) },
          errorHandler: { @Sendable error in reply.finish(.failure(error)) })
      }
      let reply = try JSONDecoder().decode(CompanionReply.self, from: response)
      LocalAlertJournal.record("phone_reply_received", eventID: command.event?.id,
        details: ["commandID": command.identifier, "accepted": String(reply.accepted),
          "retryable": String(reply.retryable == true), "message": reply.message])
      apply(reply.snapshot)
      #if os(watchOS)
        if command.response != nil {
          consume(reply.commandID == nil ? reply.acknowledging(command) : reply)
        }
      #endif
      if command.response != nil || initialConnection || !reply.accepted {
        notice = reply.accepted ? "" : reply.message
      }
      if command.response == nil, reply.accepted, !hasPendingResponse { notice = "" }
      reachable = session.isReachable
    } catch {
      Self.logger.info("Interactive Watch transfer deferred: \(error.localizedDescription, privacy: .public)")
      if command.response != nil {
        notice = "Not confirmed. Retry your response or open MediNag on iPhone."
      } else if !CompanionTransportFailures.isTransient(error) {
        notice = "Could not refresh from iPhone. \(error.localizedDescription)"
      } else if snapshot?.ready != true {
        notice = "Waiting for schedule from iPhone."
      }
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
        let waiting = activationWaiters.values
        activationWaiters.removeAll()
        for waiter in waiting {
          if let error { waiter.finish(.failure(error)) }
          else { waiter.finish(.success(Data())) }
        }
        completeDrainedTransfers()
        // Queue durable responses before a refresh round trip can consume
        // the short background slot granted for a notification action.
        if let pendingResponse { queueResponse(pendingResponse) }
        if connected || WKApplication.shared().applicationState == .active {
          await refreshOnActivation()
        }
      #endif
    }
  }

  nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
    let connected = session.isReachable
    Task { @MainActor in
      reachable = connected
      #if os(watchOS)
        if connected { await refreshOnActivation() }
      #else
        if connected, let value = latestSnapshot { publish(value) }
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
    guard value.canReplace(snapshot) else { return }
    if snapshot?.patientID != value.patientID || snapshot?.administratorID != value.administratorID {
      notice = ""
    }
    let merged = value.preservingResponseProgress(from: snapshot)
    snapshot = merged
    if value.ready, notice == "Waiting for schedule from iPhone." { notice = "" }
    #if os(watchOS)
      UserDefaults.standard.set(try? JSONEncoder().encode(merged), forKey: "medinag.watch.snapshot")
      discardSupersededResponse()
      if let pendingResponse { queueResponse(pendingResponse) }
      notificationWork = Task {
        await reconcileWatchNotifications(requestPermission: WKApplication.shared().applicationState == .active)
      }
    #endif
  }

  nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
    if let failure = userInfo["watchNotificationFailure"] as? String {
      Task { @MainActor in await reportNotificationFailure?(failure) }
      return
    }
    #if os(watchOS)
      if let data = userInfo["reply"] as? Data,
        let reply = try? JSONDecoder().decode(CompanionReply.self, from: data) {
        Task { @MainActor in consume(reply) }
        return
      }
    #endif
    guard let data = userInfo["command"] as? Data,
          let command = try? JSONDecoder().decode(CompanionCommand.self, from: data) else { return }
    Task { @MainActor in
      guard let handleCommand else { return }
      let reply = await handleCommand(command).acknowledging(command)
      publish(reply.snapshot)
      if let data = try? JSONEncoder().encode(reply) {
        self.session?.transferUserInfo(["reply": data])
      }
    }
  }

  #if os(watchOS)
    private func waitForActivationIfNeeded() async {
      guard let session, session.activationState != .activated else { return }
      let id = UUID()
      defer { activationWaiters.removeValue(forKey: id) }
      do {
        let _: Data = try await withCheckedThrowingContinuation { continuation in
          let waiter = CompanionMessageReply(continuation)
          activationWaiters[id] = waiter
          // Product execution-budget timeout, not a test delay. Completion
          // normally follows the actual WCSession activation callback.
          waiter.armTimeout(after: 2)
          if session.activationState == .notActivated { session.activate() }
        }
      } catch {
        LocalAlertJournal.record("response_transfer_activation_deferred", details: ["error": error.localizedDescription])
      }
    }

    private static let maintenanceDateKey = "medinag.watch.requested-maintenance"

    func requestBackgroundMaintenance() {
      guard let snapshot = presentationSnapshot, snapshot.ready else { return }
      let now = snapshot.logicalDate.addingTimeInterval(Date().timeIntervalSince(snapshot.realDate) / snapshot.clockScale)
      let plan = ReminderPlan(events: snapshot.events, now: now,
        snoozeInterval: Double(snapshot.snoozeMinutes * 60), repeatInterval: Double((snapshot.repeatMinutes ?? 3) * 60))
      let logical = ReminderRefreshPolicy.preferredDate(now: now, events: snapshot.events, coveredThrough: plan.coveredThrough)
      let preferred = Date().addingTimeInterval(logical.timeIntervalSince(now) * snapshot.clockScale)
      if let pending = UserDefaults.standard.object(forKey: Self.maintenanceDateKey) as? Date,
        pending > Date(), pending <= preferred { return }
      UserDefaults.standard.set(preferred, forKey: Self.maintenanceDateKey)
      WKApplication.shared().scheduleBackgroundRefresh(withPreferredDate: preferred,
        userInfo: "medinag.queue-refresh" as NSString) { error in
        if let error {
          LocalAlertJournal.record("background_refresh_request_failed", details: ["error": error.localizedDescription])
          if UserDefaults.standard.object(forKey: Self.maintenanceDateKey) as? Date == preferred {
            UserDefaults.standard.removeObject(forKey: Self.maintenanceDateKey)
          }
        } else {
          LocalAlertJournal.record("background_refresh_requested", deadline: preferred,
            details: ["identifier": "medinag.queue-refresh"])
        }
      }
    }

    func refreshInBackground() async {
      UserDefaults.standard.removeObject(forKey: Self.maintenanceDateKey)
      LocalAlertJournal.record("background_refresh_started")
      await reconcileWatchNotifications() // Repair the independent Watch queue first.
      // A real background transfer also requests fresh data when immediate
      // messaging cannot finish inside the Watch's short execution allowance.
      let command = CompanionCommand()
      if let session, session.activationState == .activated,
        !session.outstandingUserInfoTransfers.contains(where: {
          guard let data = $0.userInfo["command"] as? Data,
            let pending = try? JSONDecoder().decode(CompanionCommand.self, from: data) else { return false }
          return pending.response == nil
        }), let data = try? JSONEncoder().encode(command) {
        session.transferUserInfo(["command": data])
      }
      await refresh(timeout: 2)
      requestBackgroundMaintenance()
      LocalAlertJournal.record("background_refresh_finished")
    }

    func doseWindowDidChange() async {
      discardSupersededResponse()
      await reconcileWatchNotifications()
    }

    private func queueResponse(_ command: CompanionCommand) {
      guard let session, session.activationState == .activated else { return }
      let queued = session.outstandingUserInfoTransfers.contains {
        guard let data = $0.userInfo["command"] as? Data,
          let existing = try? JSONDecoder().decode(CompanionCommand.self, from: data) else { return false }
        return existing.identifier == command.identifier
      }
      if !queued, let data = try? JSONEncoder().encode(command) {
        session.transferUserInfo(["command": data])
      }
    }

    private func clearResponse() {
      if let pending = pendingResponse {
        for transfer in session?.outstandingUserInfoTransfers ?? [] {
          if let data = transfer.userInfo["command"] as? Data,
             let command = try? JSONDecoder().decode(CompanionCommand.self, from: data),
             command.identifier == pending.identifier { transfer.cancel() }
        }
      }
      pendingResponse = nil
    }

    private func discardSupersededResponse() {
      guard let pending = pendingResponse, let snapshot else { return }
      if !pending.remainsPending(in: snapshot, at: Date()) {
        clearResponse()
        notice = ""
      }
    }

    private func consume(_ reply: CompanionReply) {
      let resolves = pendingResponse.map { reply.resolves($0) } ?? false
      let matches = pendingResponse?.identifier == reply.commandID
      apply(reply.snapshot)
      if resolves { clearResponse() }
      if matches { notice = reply.accepted ? "" : reply.message }
    }

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
        guard let snapshot = presentationSnapshot else { return }
        if !snapshot.ready {
          _ = try await notifications.reconcile(events: [], snoozeInterval: 600, logicalNow: Date())
          return
        }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if requestPermission && WKApplication.shared().applicationState == .active
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
          snoozeInterval: Double(snapshot.snoozeMinutes * 60),
          repeatInterval: Double((snapshot.repeatMinutes ?? 3) * 60), logicalNow: now,
          clockScale: snapshot.clockScale, snapshot: snapshot)
        requestBackgroundMaintenance()
        if notice == "Allow MediNag notifications in Watch Settings."
          || notice == "Watch reminders failed. Open MediNag on iPhone." {
          notice = ""
        }
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
      let reply = await handleCommand(command).acknowledging(command)
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
    LocalAlertJournal.record("foreground_presentation_callback", requestID: notification.request.identifier)
    completionHandler([.banner, .list, .sound])
  }

  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
    let action = response.actionIdentifier
    let data = response.notification.request.content.userInfo[MediNagNotification.command] as? Data
    let completion = WatchNotificationCompletion(finish: completionHandler)
    LocalAlertJournal.record("notification_action_callback", requestID: response.notification.request.identifier,
      details: ["action": action])
    // A dismiss/default tap does not answer the dose or cancel its queue.
    guard let choice: DoseResponse = action == MediNagNotification.yesIDid ? .yesIDid
      : action == MediNagNotification.yesIWill ? .yesIWill : nil,
      let data, let command = try? JSONDecoder().decode(CompanionCommand.self, from: data),
      let event = command.event else {
      if action == MediNagNotification.yesIDid || action == MediNagNotification.yesIWill {
        LocalAlertJournal.record("response_rejected", requestID: response.notification.request.identifier,
          details: ["reason": "missing_or_invalid_notification_payload"])
      }
      completion.finish(); return
    }
    Task { @MainActor in
      defer { completion.finish() }
      guard let snapshot, command.patientID == snapshot.patientID,
        command.administratorID == snapshot.administratorID,
        snapshot.events.contains(where: {
          choice == .yesIDid ? $0.hasSameOccurrence(as: event) : $0.hasSameResponseVersion(as: event)
        }) else {
        notice = "This dose changed. Check the current dose."
        LocalAlertJournal.record("response_rejected", eventID: event.id,
          details: ["reason": "notification_snapshot_mismatch"])
        return
      }
      let current = presentationSnapshot?.events.first(where: { $0.hasSameOccurrence(as: event) }) ?? event
      await respond(choice, to: current)
    }
  }
}
private struct WatchNotificationCompletion: @unchecked Sendable { let finish: () -> Void }
#endif
