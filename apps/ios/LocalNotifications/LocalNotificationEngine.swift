@preconcurrency import AlarmKit
import Foundation
import MediNagCore
import OSLog
@preconcurrency import UserNotifications

/// Alternative executable implementation, not compiled alongside AlarmKit's
/// engine. Every mutation is serialized across SDK awaits; network is outside.
actor PatientAlarmEngine {
  static let shared = PatientAlarmEngine()
  private let center = UNUserNotificationCenter.current()
  private let logger = Logger(subsystem: "org.boardgamescafe.medinag", category: "LocalNotifications")
  private var state: PatientAlarmState
  private var tail: Task<Void, Never>?
  enum Command: Sendable {
    case importEvents(PatientAlarmState.Context, [MedicationEvent])
    case reconcile, clear
    case respond(String, DoseResponse)
    case notificationAction(LocalNotificationTap)
    case observed(String, String, Date)
    case acknowledgedResponse(String)
    case acknowledgedEvidence([String])
    case failure(String)
  }
  init() {
    do { state = try PatientAlarmDisk.load() }
    catch {
      state = PatientAlarmState()
      state.lastFailure = "Local notification data could not be restored: \(error.localizedDescription)"
    }
    if state.bindings.contains(where: { $0.configurationVersion != 100 }) {
      state.verifiedAlarmIDs = []; state.verifiedThrough = nil; state.verificationObservedAt = nil
    }
  }
  func snapshot() -> PatientAlarmState { state }
  func run(_ command: Command) async -> PatientAlarmState {
    let previous = tail
    let work = Task { await previous?.value; return await self.perform(command) }
    tail = Task { _ = await work.value }
    return await work.value
  }
  private func perform(_ command: Command) async -> PatientAlarmState {
    do {
      switch command {
      case .importEvents(let context, let incoming):
        guard context.plan.snoozeIntervalMinutes > context.plan.repeatIntervalMinutes,
          context.plan.repeatIntervalMinutes > 0 else { throw Failure("Invalid server reminder intervals.") }
        if let old = state.context, old.patientID != context.patientID || old.plan.id != context.plan.id {
          throw Failure("Sign out before changing accounts or schedules.")
        }
        state.context = context
        state.events = AlertTiming.applyingPolicy(to: incoming, previous: state.events, at: Date(),
          snoozeInterval: Double(context.plan.snoozeIntervalMinutes * 60),
          repeatInterval: Double(context.plan.repeatIntervalMinutes * 60))
        for tap in state.responses where !state.events.contains(where: { $0.id == tap.event.id }) {
          state.events.append(tap.updatedEvent)
        }
        try trace("schedule_received", detail: "\(incoming.count) real Firestore occurrences; local notifications")
        try await reconcile()
      case .reconcile: try await reconcile()
      case .respond(let eventID, let response): try await respond(eventID, response: response)
      case .notificationAction(let tap):
        let eventID = tap.eventID, action = tap.action
        guard state.context?.patientID == tap.patientID, state.context?.plan.id == tap.administratorID,
          let event = state.events.first(where: { $0.id == eventID }),
          event.scheduledTime.timeIntervalSince1970 == tap.scheduledTime, event.snoozeCount == tap.snoozeCount else {
          try trace("stale_notification_action_ignored", eventID: eventID, detail: "Account/schedule/occurrence/response version no longer matches")
          break
        }
        try trace("notification_action_callback", eventID: eventID,
          detail: "\(tap.id) action=\(action); secondsFromExpectedAlert=\(Date().timeIntervalSince1970 - tap.expectedAt)")
        if action == LocalNotificationActions.did { try await respond(eventID, response: .yesIDid) }
        else if action == LocalNotificationActions.will { try await respond(eventID, response: .yesIWill) }
        else {
          // Opening/dismissing is NOT a medication response and never cancels
          // future retries. Body taps show the same minimal response screen.
          if action == UNNotificationDefaultActionIdentifier, state.latestDue(at: Date())?.id == eventID {
            state.responseEventID = eventID
          }
          try await reconcile()
        }
      case .observed(let id, let eventID, let date):
        try trace("notification_observed", eventID: eventID,
          detail: "\(id) systemDate=\(date.ISO8601Format()); not audible-delivery proof")
      case .acknowledgedResponse(let id):
        state.responses.removeAll { $0.id == id }
        try trace("response_server_acknowledged", detail: id)
      case .acknowledgedEvidence(let ids):
        state.evidence.removeAll { ids.contains($0.id) }; try PatientAlarmDisk.save(state)
      case .failure(let message): throw Failure(message)
      case .clear:
        center.removeAllPendingNotificationRequests(); center.removeAllDeliveredNotifications()
        if AlarmManager.shared.authorizationState == .authorized {
          for alarm in try AlarmManager.shared.alarms { try AlarmManager.shared.cancel(id: alarm.id) }
        }
        state = PatientAlarmState(); try PatientAlarmDisk.save(state)
      }
    } catch {
      let changed = state.lastFailure != error.localizedDescription
      state.lastFailure = error.localizedDescription
      let actual = await center.pendingNotificationRequests()
      state.verifiedAlarmIDs = actual.compactMap { UUID(uuidString: $0.identifier) }
      state.verificationObservedAt = Date()
      if changed { try? trace("client_failure", detail: error.localizedDescription) }
      logger.error("\(error.localizedDescription, privacy: .public)")
    }
    return state
  }
  private func reconcile() async throws {
    guard let context = state.context else { return }
    // No AlarmKit scheduling in this executable. Remove old registrations even
    // when notification permission has not yet been granted.
    if AlarmManager.shared.authorizationState == .authorized {
      for alarm in try AlarmManager.shared.alarms { try AlarmManager.shared.cancel(id: alarm.id) }
      guard try AlarmManager.shared.alarms.isEmpty else { throw Failure("Legacy AlarmKit alarms remain.") }
    }
    let settings = await center.notificationSettings()
    if settings.authorizationStatus == .notDetermined {
      state.lastFailure = "Notification permission has not been granted."
      state.verifiedAlarmIDs = []; state.verifiedThrough = nil
      state.verificationObservedAt = Date()
      try PatientAlarmDisk.save(state)
      return
    }
    guard settings.authorizationStatus == .authorized, settings.alertSetting == .enabled,
      settings.soundSetting == .enabled else { throw Failure("Enable notification alerts and sounds in Settings.") }
    #if MEDINAG_CRITICAL_ALERTS
    guard settings.criticalAlertSetting == .enabled else { throw Failure("Critical Alerts permission is required.") }
    #endif
    let now = Date()
    let oldInventory = await center.pendingNotificationRequests()
    #if MEDINAG_CRITICAL_ALERTS
    let level: UNNotificationInterruptionLevel = .critical
    #else
    let level: UNNotificationInterruptionLevel = .active
    #endif
    // Do not delete the just-due request while iOS is still consuming it.
    // Keep only the newest in-flight request for the current response version;
    // this is not replaying a past alarm or retaining obsolete dose history.
    let latest = state.latestDue(at: now)
    let inFlight = state.bindings.filter { binding in
      binding.configurationVersion == 100 && binding.eventID == latest?.id && binding.deadline <= now
        && latest.map { binding.deadline >= AlertTiming.reminder(for: $0,
          snoozeInterval: Double(context.plan.snoozeIntervalMinutes * 60)) } == true
        && oldInventory.contains { $0.identifier == binding.id.uuidString && $0.content.interruptionLevel == level }
    }.max { $0.deadline < $1.deadline }
    let plan = LocalNotificationPlan.make(events: state.eligibleEvents, at: now,
      repeatInterval: Double(context.plan.repeatIntervalMinutes * 60),
      budget: LocalNotificationPlan.capacity - (inFlight == nil ? 0 : 1))
    var bindings: [PatientAlarmState.Binding] = inFlight.map { [$0] } ?? []
    for slot in plan.slots {
      let existing = state.bindings.first { $0.configurationVersion == 100 && $0.eventID == slot.eventID
        && $0.deadline == slot.deadline }
      bindings.append(existing ?? .init(id: UUID(), eventID: slot.eventID, deadline: slot.deadline,
        followup: true, snoozeSeconds: 0, configurationVersion: 100))
    }
    let desired = Set(bindings.map { $0.id.uuidString })
    center.removePendingNotificationRequests(withIdentifiers: oldInventory.map(\.identifier).filter { !desired.contains($0) })
    let latestID = state.latestDue(at: now)?.id
    let delivered = await center.deliveredNotifications()
    center.removeDeliveredNotifications(withIdentifiers: delivered.filter {
      let id = $0.request.content.userInfo["eventID"] as? String
      return id != latestID || state.events.first { $0.id == id }?.status == .snoozed
    }.map { $0.request.identifier })
    state.bindings = bindings
    try PatientAlarmDisk.save(state) // Preserve request identities across a crash/retry.
    for binding in bindings {
      if binding.id == inFlight?.id { continue }
      let content = UNMutableNotificationContent()
      content.title = "Medication reminder"
      content.body = "Please respond."
      content.categoryIdentifier = LocalNotificationActions.category
      // Do not coalesce separate dose/retry identifiers into an implicit summary.
      content.threadIdentifier = "medinag-dose"
      guard let event = state.events.first(where: { $0.id == binding.eventID }) else { continue }
      content.userInfo = ["eventID": binding.eventID, "patientID": context.patientID,
        "administratorID": context.plan.id, "deadline": binding.deadline.timeIntervalSince1970,
        "scheduledTime": event.scheduledTime.timeIntervalSince1970, "snoozeCount": event.snoozeCount]
      #if MEDINAG_CRITICAL_ALERTS
      content.interruptionLevel = .critical
      content.sound = .defaultCriticalSound(withAudioVolume: 1)
      #else
      content.interruptionLevel = .active
      content.sound = .default
      #endif
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = TimeZone(secondsFromGMT: 0)!
      var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: binding.deadline)
      components.timeZone = calendar.timeZone
      let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
      if let existing = oldInventory.first(where: { $0.identifier == binding.id.uuidString }),
        let oldTrigger = existing.trigger as? UNCalendarNotificationTrigger,
        oldTrigger.nextTriggerDate() == trigger.nextTriggerDate(),
        existing.content.categoryIdentifier == content.categoryIdentifier,
        existing.content.interruptionLevel == content.interruptionLevel { continue }
      try trace("registration_requested", eventID: binding.eventID,
        detail: "\(binding.id) deadline=\(binding.deadline.ISO8601Format())")
      try await center.add(UNNotificationRequest(identifier: binding.id.uuidString, content: content, trigger: trigger))
      try trace("registration_add_accepted", eventID: binding.eventID, detail: binding.id.uuidString)
    }
    let actual = await center.pendingNotificationRequests()
    guard Set(actual.map(\.identifier)) == desired, actual.count <= LocalNotificationPlan.capacity else {
      throw Failure("Local notification pending inventory differs from the requested plan.")
    }
    for binding in bindings {
      guard let request = actual.first(where: { $0.identifier == binding.id.uuidString }),
        let trigger = request.trigger as? UNCalendarNotificationTrigger,
        request.content.interruptionLevel == level,
        trigger.nextTriggerDate() == binding.deadline || binding.id == inFlight?.id else { throw Failure("A notification deadline failed OS readback.") }
      if !binding.verified {
        try trace("registration_verified", eventID: binding.eventID,
          detail: "\(binding.id); actual pending request/deadline/urgency read back; not delivery")
      }
    }
    state.bindings = bindings.map { var binding = $0; binding.verified = true; return binding }
    state.verifiedAlarmIDs = bindings.map(\.id)
    state.verifiedThrough = bindings.map(\.deadline).max()
    state.verificationObservedAt = Date()
    state.lastFailure = nil
    try trace("inventory_verified", detail: "\(actual.count) actual local notifications; mode=\(LocalNotificationActions.mode); coverageComplete=\(plan.complete); registration is not delivery")
    if !plan.complete { throw Failure("Server settings exceed capacity for two complete 30-minute dose windows; administrator must adjust intervals.") }
  }
  private func respond(_ eventID: String, response: DoseResponse) async throws {
    guard let context = state.context, let index = state.events.firstIndex(where: { $0.id == eventID }) else { return }
    let event = state.events[index], now = Date()
    guard event.status != .completed,
      AlertTiming.canComplete(event, among: state.eligibleEvents, at: now,
        snoozeInterval: Double(context.plan.snoozeIntervalMinutes * 60)),
      response == .yesIDid || event.scheduledTime <= now else {
      try trace("stale_notification_action_ignored", eventID: eventID, detail: response.rawValue)
      return
    }
    let tap = LocalDoseResponse(patientID: context.patientID, administratorID: context.plan.id,
      event: event, response: response, respondedAt: now,
      snoozeInterval: Double(context.plan.snoozeIntervalMinutes * 60))
    state.responses.append(tap)
    state.events[index] = tap.updatedEvent
    if response == .yesIDid, event.scheduledTime > now {
      state.retiredBefore = max(state.retiredBefore ?? .distantPast, event.scheduledTime)
    }
    state.responseEventID = nil
    try trace("patient_response_saved", eventID: eventID,
      detail: "\(tap.id) \(response.rawValue); secondsFromDose=\(now.timeIntervalSince(event.scheduledTime)); snooze=\(tap.snoozeDeadline.ISO8601Format())")
    let ids = state.bindings.filter { $0.eventID == eventID }.map { $0.id.uuidString }
    center.removePendingNotificationRequests(withIdentifiers: ids)
    center.removeDeliveredNotifications(withIdentifiers: ids)
    guard !(await center.pendingNotificationRequests()).contains(where: { ids.contains($0.identifier) }) else {
      throw Failure("Responded dose still has pending notifications.")
    }
    state.bindings.removeAll { $0.eventID == eventID }
    try trace("dose_cancellation_verified", eventID: eventID, detail: "\(ids.count) previous requests absent; \(response.rawValue)")
    try await reconcile()
  }
  private func trace(_ kind: String, eventID: String = "", detail: String = "") throws {
    state.evidence.append(.init(id: UUID().uuidString, kind: kind, eventID: eventID,
      observedAt: Date(), detail: String(detail.prefix(1000))))
    logger.info("\(kind, privacy: .public) \(eventID, privacy: .public) \(detail, privacy: .public)")
    try PatientAlarmDisk.save(state)
  }
  struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
  }
}
