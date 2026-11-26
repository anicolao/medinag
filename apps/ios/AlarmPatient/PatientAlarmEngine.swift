import ActivityKit
@preconcurrency import AlarmKit
import Foundation
import MediNagCore
import OSLog
import UserNotifications

/// One local owner. Commands are FIFO across SDK awaits; no network request is
/// ever allowed into this queue. The file is the sole schedule/response truth.
actor PatientAlarmEngine {
  static let shared = PatientAlarmEngine()
  static let initialAlarmBudget = 32
  private let manager = AlarmManager.shared
  private var state: PatientAlarmState
  private var tail: Task<Void, Never>?
  private let logger = Logger(subsystem: "org.boardgamescafe.medinag", category: "PatientAlarmKit")

  enum Command: Sendable {
    case importEvents(PatientAlarmState.Context, [MedicationEvent])
    case reconcile
    case stop(UUID)
    case snooze(UUID)
    case respond(String, DoseResponse)
    case acknowledgedResponse(String)
    case acknowledgedEvidence([String])
    case failure(String)
    case observeOS(UUID, String)
    case clear
  }

  init() {
    do { state = try PatientAlarmDisk.load() }
    catch {
      state = PatientAlarmState()
      state.lastFailure = "Local alarm data could not be restored: \(error.localizedDescription)"
    }
  }

  func snapshot() -> PatientAlarmState { state }

  func run(_ command: Command) async -> PatientAlarmState {
    let previous = tail
    let work = Task {
      await previous?.value
      return await self.perform(command)
    }
    tail = Task { _ = await work.value }
    return await work.value
  }

  private func perform(_ command: Command) async -> PatientAlarmState {
    do {
      switch command {
      case .importEvents(let context, let incoming):
        guard context.plan.snoozeIntervalMinutes > 0, context.plan.repeatIntervalMinutes > 0 else {
          throw Failure("The server reminder intervals are invalid.")
        }
        if let existing = state.context, existing.patientID != context.patientID
          || existing.plan.id != context.plan.id {
          throw Failure("Sign out before changing the patient or followed schedule.")
        }
        let previous = state.events
        state.context = context
        state.events = incoming.map { event in
          previous.first(where: { $0.id == event.id }).map { event.preservingResponseProgress(from: $0) } ?? event
        }
        // Never lose an offline response merely because its occurrence was
        // omitted from a newly fetched server list.
        for response in state.responses where !state.events.contains(where: { $0.id == response.event.id }) {
          state.events.append(response.updatedEvent)
        }
        try trace("schedule_received", detail: "\(incoming.count) real Firestore occurrences")
        try await reconcile()
      case .reconcile:
        try await reconcile()
      case .stop(let id):
        try await handleStop(id)
      case .snooze(let id):
        try await handleSnooze(id)
      case .respond(let eventID, let response):
        try await respond(eventID: eventID, response: response)
      case .acknowledgedResponse(let id):
        state.responses.removeAll { $0.id == id }
        try trace("response_server_acknowledged", detail: id)
      case .acknowledgedEvidence(let ids):
        state.evidence.removeAll { ids.contains($0.id) }
        try PatientAlarmDisk.save(state)
      case .failure(let message):
        throw Failure(message)
      case .observeOS(let id, let value):
        let eventID = state.bindings.first(where: { $0.id == id })?.eventID ?? ""
        try trace("os_state_observed", eventID: eventID, detail: "\(id) \(value); observation is not audible-delivery proof")
      case .clear:
        for alarm in try manager.alarms { try manager.cancel(id: alarm.id) }
        state = PatientAlarmState()
        try PatientAlarmDisk.save(state)
      }
    } catch {
      let changed = state.lastFailure != error.localizedDescription
      state.lastFailure = error.localizedDescription
      logger.error("Patient alarm failure: \(error.localizedDescription, privacy: .public)")
      if changed { try? trace("client_failure", detail: error.localizedDescription) }
    }
    return state
  }

  private func reconcile() async throws {
    guard state.context != nil else { return }
    if manager.authorizationState == .notDetermined {
      try trace("alarm_permission_not_yet_requested")
      return
    }
    guard manager.authorizationState == .authorized else {
      throw Failure("Alarms are disabled. Enable MediNag alarms in Settings.")
    }
    let now = Date()
    let latest = state.latestDue(at: now)
    let future = Array(state.eligibleEvents.filter { $0.scheduledTime > now && $0.status != .completed }
      .sorted { $0.scheduledTime < $1.scheduledTime }.prefix(Self.initialAlarmBudget))
    var desired = Set<UUID>()
    var inventory = try manager.alarms
    for event in future {
      let snooze = Double(state.context!.plan.snoozeIntervalMinutes * 60)
      if let binding = state.bindings.first(where: { $0.eventID == event.id
        && $0.deadline == event.scheduledTime && $0.snoozeSeconds == snooze }),
        inventory.contains(where: { $0.id == binding.id && $0.schedule == .fixed(binding.deadline) }) {
        desired.insert(binding.id)
        continue
      }
      let binding = PatientAlarmState.Binding(id: UUID(), eventID: event.id,
        deadline: event.scheduledTime, followup: false, snoozeSeconds: snooze)
      try await install(binding, event: event)
      desired.insert(binding.id)
      inventory = try manager.alarms
    }
    // Keep actual already-due alarms for the latest dose. Never replay the past.
    if let latest {
      for binding in state.bindings where binding.eventID == latest.id
        && inventory.contains(where: { $0.id == binding.id }) {
        desired.insert(binding.id)
      }
    }
    if state.responseEventID != latest?.id { state.responseEventID = nil }
    for alarm in try manager.alarms where !desired.contains(alarm.id) {
      try manager.cancel(id: alarm.id)
    }
    state.bindings.removeAll { !desired.contains($0.id) }
    let final = try manager.alarms
    guard Set(final.map(\.id)) == desired else { throw Failure("AlarmKit inventory differs from the registered dose plan.") }
    if !state.migrated {
      let center = UNUserNotificationCenter.current()
      center.removeAllPendingNotificationRequests()
      center.removeAllDeliveredNotifications()
      guard await center.pendingNotificationRequests().isEmpty else {
        throw Failure("Legacy phone notifications could not be removed.")
      }
      state.migrated = true
    }
    state.verifiedThrough = future.last?.scheduledTime
    state.verifiedAlarmIDs = final.map(\.id)
    state.verificationObservedAt = Date()
    state.lastFailure = nil
    try trace("inventory_verified", detail: "\(final.count) actual alarms; first \(future.count) future doses")
  }

  private func install(_ binding: PatientAlarmState.Binding, event: MedicationEvent) async throws {
    state.bindings.removeAll { $0.id == binding.id }
    state.bindings.append(binding)
    try trace("registration_requested", eventID: event.id,
      detail: "\(binding.id) deadline=\(binding.deadline.ISO8601Format())")
    let attributes = AlarmAttributes(presentation: AlarmPresentation(
      alert: AlarmPresentation.Alert(title: "Time for medication",
        secondaryButton: AlarmButton(text: "Snooze", textColor: .white, systemImageName: "zzz"),
        secondaryButtonBehavior: .countdown),
      countdown: AlarmPresentation.Countdown(title: "Medication reminder")),
      metadata: PrototypeMetadata(requestedAt: Date(), deadline: binding.deadline, title: event.medicationName), tintColor: .teal)
    let remaining = binding.deadline.timeIntervalSinceNow
    let shortCountdown = binding.followup && remaining > 0 && remaining <= 3600 ? remaining : nil
    let configuration = AlarmManager.AlarmConfiguration(
      // A scheduled medication is a fixed-date alarm, not a multi-day timer.
      // Long preAlert countdowns are rejected by AlarmKit (next-day error 0).
      // Live Activity/countdown support remains for the post-alert snooze.
      countdownDuration: Alarm.CountdownDuration(preAlert: shortCountdown,
        postAlert: binding.snoozeSeconds), schedule: .fixed(binding.deadline), attributes: attributes,
      stopIntent: PatientStopIntent(alarmID: binding.id),
      secondaryIntent: PatientSnoozeIntent(alarmID: binding.id), sound: .named("MediNagAlarm.caf"))
    _ = try await manager.schedule(id: binding.id, configuration: configuration)
    guard try manager.alarms.contains(where: { $0.id == binding.id && $0.schedule == .fixed(binding.deadline) }) else {
      throw Failure("AlarmKit did not confirm the requested dose deadline.")
    }
    if let index = state.bindings.firstIndex(where: { $0.id == binding.id }) { state.bindings[index].verified = true }
    try trace("registration_verified", eventID: event.id, detail: binding.id.uuidString)
  }

  private func handleStop(_ id: UUID) async throws {
    guard let binding = state.bindings.first(where: { $0.id == id }),
      let event = state.eligibleEvents.first(where: { $0.id == binding.eventID }), event.status != .completed,
      state.latestDue(at: Date())?.id == event.id || state.nextDose(at: Date())?.id == event.id else {
      if try manager.alarms.contains(where: { $0.id == id }) { try manager.cancel(id: id) }
      state.bindings.removeAll { $0.id == id }
      try trace("obsolete_stop_ignored", detail: id.uuidString)
      return
    }
    state.responseEventID = event.id
    try trace("system_stop_received", eventID: event.id, detail: id.uuidString)
    let repeatSeconds = Double(state.context!.plan.repeatIntervalMinutes * 60)
    let origin = event.snoozedUntil ?? event.scheduledTime
    let deadline = origin > Date() ? origin : PatientAlarmState.gridDeadline(origin: origin, now: Date(), interval: repeatSeconds)
    try await replaceActive(event: event, deadline: deadline)
    try await reconcile()
  }

  private func handleSnooze(_ id: UUID) async throws {
    guard let binding = state.bindings.first(where: { $0.id == id }),
      let event = state.latestDue(at: Date()), event.id == binding.eventID else {
      // Snoozing a retired alert must not leave a new OS countdown for it.
      if try manager.alarms.contains(where: { $0.id == id }) { try manager.cancel(id: id) }
      state.bindings.removeAll { $0.id == id }
      try trace("obsolete_snooze_ignored", detail: id.uuidString)
      return
    }
    try trace("system_snooze_received", eventID: event.id, detail: id.uuidString)
    try await respond(eventID: event.id, response: .yesIWill)
  }

  private func respond(eventID: String, response: DoseResponse) async throws {
    guard let context = state.context, let index = state.events.firstIndex(where: { $0.id == eventID }) else { return }
    let event = state.events[index]
    let now = Date()
    guard event.status != .completed else { return }
    if event.scheduledTime > now {
      guard response == .yesIDid, event.scheduledTime.timeIntervalSince(now) <= 900,
        state.nextDose(at: now)?.id == event.id else { return }
    } else {
      guard state.latestDue(at: now)?.id == event.id else { return }
    }
    let intent = LocalDoseResponse(patientID: context.patientID, administratorID: context.plan.id,
      event: event, response: response, respondedAt: now,
      snoozeInterval: Double(context.plan.snoozeIntervalMinutes * 60))
    state.responses.append(intent)
    state.events[index] = intent.updatedEvent
    try trace("patient_response_saved", eventID: event.id, detail: "\(intent.id) \(response.rawValue)")
    if response == .yesIWill {
      try await replaceActive(event: intent.updatedEvent, deadline: intent.snoozeDeadline)
    } else {
      try await cancel(eventID: event.id)
      if event.scheduledTime > now {
        state.retiredBefore = max(state.retiredBefore ?? .distantPast, event.scheduledTime)
        try trace("older_alerts_retired_after_early_completion", eventID: event.id)
      }
    }
    state.responseEventID = nil
    try await reconcile()
  }

  private func replaceActive(event: MedicationEvent, deadline: Date) async throws {
    if let successor = state.successor(of: event), deadline >= successor {
      // The next initial dose is already registered. Never arm an old snooze
      // or follow-up at/after that successor.
      try await cancel(eventID: event.id)
      try trace("followup_retired_at_successor", eventID: event.id)
      return
    }
    let replacement = PatientAlarmState.Binding(id: UUID(), eventID: event.id, deadline: deadline,
      followup: true, snoozeSeconds: Double(state.context!.plan.snoozeIntervalMinutes * 60))
    let retired = state.bindings.filter { $0.eventID == event.id }.map(\.id)
    try await install(replacement, event: event)
    for id in retired where try manager.alarms.contains(where: { $0.id == id }) {
      try manager.cancel(id: id)
    }
    state.bindings.removeAll { retired.contains($0.id) }
    try trace("followup_verified_before_return", eventID: event.id,
      detail: "\(replacement.id) deadline=\(deadline.ISO8601Format())")
  }

  private func cancel(eventID: String) async throws {
    let ids = state.bindings.filter { $0.eventID == eventID }.map(\.id)
    for id in ids where try manager.alarms.contains(where: { $0.id == id }) { try manager.cancel(id: id) }
    guard try !manager.alarms.contains(where: { ids.contains($0.id) }) else {
      throw Failure("The completed dose still has an OS alarm.")
    }
    state.bindings.removeAll { ids.contains($0.id) }
    try trace("dose_cancellation_verified", eventID: eventID)
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
