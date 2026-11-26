import ActivityKit
import AppIntents
@preconcurrency import AlarmKit
import Combine
import OSLog
import SwiftUI
import UserNotifications

@main
struct PrototypeApp: App {
  @StateObject private var model = PrototypeModel.shared
  @Environment(\.scenePhase) private var scenePhase

  var body: some Scene {
    WindowGroup {
      PrototypeView(model: model)
        .task { await model.observe() }
        .onChange(of: scenePhase) { _, phase in
          if phase == .active { model.refresh() }
        }
    }
  }
}

@MainActor
final class PrototypeModel: ObservableObject {
  static let shared = PrototypeModel()
  @Published var minutes = 1
  @Published private(set) var busy = false
  @Published private(set) var alarm: Alarm?
  @Published private(set) var deadline: Date?
  @Published private(set) var authorization = AlarmManager.shared.authorizationState
  @Published private(set) var errorMessage: String?
  @Published private(set) var report: String = "No test scheduled."
  @Published private(set) var responseRequired = false
  private let manager = AlarmManager.shared
  private let defaults = UserDefaults.standard
  private let logger = Logger(subsystem: "org.boardgamescafe.medinag", category: "AlarmPrototype")
  private let key = "medinag.alarm-prototype.record"
  private let cleanupKey = "medinag.alarm-prototype.cleaned-legacy-phone-queue"
  private var record: Record?
  private var storageURL: URL {
    get throws {
      let directory = try FileManager.default.url(for: .applicationSupportDirectory,
        in: .userDomainMask, appropriateFor: nil, create: true)
      return directory.appendingPathComponent("alarm-prototype.json")
    }
  }

  struct Record: Codable {
    let id: UUID
    let requestedAt: Date
    let deadline: Date
    var registeredAt: Date?
    var observations: [String]
    // Optional fields retain compatibility with build 19's stored test record.
    var activeAlarmID: UUID?
    var activeDeadline: Date?
    var responseRequired: Bool?
    var completedAt: Date?
  }

  init() {
    if let url = try? storageURL, let data = try? Data(contentsOf: url) {
      record = try? JSONDecoder().decode(Record.self, from: data)
    } else if let data = defaults.data(forKey: key) {
      record = try? JSONDecoder().decode(Record.self, from: data)
    }
    deadline = record?.activeDeadline ?? record?.deadline
    refresh()
  }

  func observe() async {
    // No Firebase, WatchConnectivity, background fetch, or application timer.
    for await alarms in manager.alarmUpdates {
      apply(alarms)
      authorization = manager.authorizationState
    }
  }

  func refresh() {
    authorization = manager.authorizationState
    do { apply(try manager.alarms) }
    catch { errorMessage = "Cannot read OS alarm inventory: \(error.localizedDescription)" }
  }

  func schedule() async {
    guard !busy else { return }
    busy = true
    errorMessage = nil
    defer { busy = false }
    do {
      authorization = try await manager.requestAuthorization()
      guard authorization == .authorized else {
        throw Failure("Alarms are not allowed. Enable MediNag in Settings → Apps → MediNag → Alarms.")
      }
      // This replacement build must not run the old medication queue as well.
      // Cleanup is explicit in the UI, and happens only after alarm permission.
      if !defaults.bool(forKey: cleanupKey) {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
        guard await center.pendingNotificationRequests().isEmpty else {
          throw Failure("The old phone notification queue could not be cleared.")
        }
        for previous in try manager.alarms { try manager.cancel(id: previous.id) }
        defaults.set(true, forKey: cleanupKey)
      }
      // Only one test alarm. Do not leave an old one behind on replacement.
      for existing in try manager.alarms {
        try manager.cancel(id: existing.id)
      }
      alarm = nil
      let requested = Date()
      let target = Date(timeIntervalSince1970: ceil(requested.timeIntervalSince1970) + Double(minutes * 60))
      let id = UUID()
      record = Record(id: id, requestedAt: requested, deadline: target, observations: [])
      deadline = target
      try persist("schedule_requested")
      try await installAlarm(id: id, at: target)
      record?.registeredAt = Date()
      try persist("registration_verified")
      apply(try manager.alarms)
    } catch {
      errorMessage = error.localizedDescription
      try? persist("schedule_failed: \(error.localizedDescription)")
      refresh()
    }
  }

  private func installAlarm(id: UUID, at target: Date) async throws {
      let presentation = AlarmPresentation(
        alert: AlarmPresentation.Alert(title: "MediNag alarm test",
          secondaryButton: AlarmButton(text: "Snooze 1 min", textColor: .white, systemImageName: "zzz"),
          secondaryButtonBehavior: .countdown),
        countdown: AlarmPresentation.Countdown(title: "MediNag alarm test"))
      let attributes = AlarmAttributes(presentation: presentation,
        metadata: PrototypeMetadata(requestedAt: Date(), deadline: target), tintColor: .teal)
      let configuration = AlarmManager.AlarmConfiguration(
        countdownDuration: Alarm.CountdownDuration(preAlert: target.timeIntervalSinceNow, postAlert: 60),
        schedule: .fixed(target), attributes: attributes,
        stopIntent: StopAndRespondIntent(alarmID: id),
        sound: .named("MediNagAlarm.caf"))
      _ = try await manager.schedule(id: id, configuration: configuration)
      let inventory = try manager.alarms
      guard let installed = inventory.first(where: { $0.id == id }),
        installed.schedule == .fixed(target) else {
        throw Failure("The OS did not confirm the exact requested alarm. Do not rely on this test.")
      }
  }

  /// Called by the real AlarmKit Stop intent, without needing a rendered scene.
  /// The intent requests deferred foreground execution only after this returns.
  func stopped(alarmID: UUID) async {
    guard let current = record, current.completedAt == nil,
      (current.activeAlarmID ?? current.id) == alarmID else {
      try? persist("stale_stop_ignored: \(alarmID)")
      return
    }
    busy = true
    errorMessage = nil
    defer { busy = false; refresh() }
    do {
      record?.responseRequired = true
      try persist("stop_received: \(alarmID)")
      // Persist the replacement identity before the OS call. A duplicate Stop
      // for the old ID cannot install a second follow-up, even after relaunch.
      let replacement = UUID()
      let target = Date(timeIntervalSince1970: ceil(Date().timeIntervalSince1970) + 60)
      record?.activeAlarmID = replacement
      record?.activeDeadline = target
      try persist("followup_registration_requested: \(replacement)")
      try await installAlarm(id: replacement, at: target)
      try persist("followup_registration_verified: \(replacement)")
      // Some OS presentations call the intent while the old alarm is still in
      // inventory. Remove it only AFTER the replacement has been verified.
      for old in try manager.alarms where old.id != replacement {
        try manager.cancel(id: old.id)
      }
    } catch {
      errorMessage = "Follow-up protection failed: \(error.localizedDescription)"
      try? persist("followup_failed: \(error.localizedDescription)")
    }
  }

  func respond(didTake: Bool) async {
    guard !busy, record?.responseRequired == true, record?.completedAt == nil else { return }
    busy = true
    errorMessage = nil
    defer { busy = false; refresh() }
    do {
      if didTake {
        try persist("patient_response: yes_i_did")
        for pending in try manager.alarms { try manager.cancel(id: pending.id) }
        guard try manager.alarms.isEmpty else { throw Failure("The OS still lists an alarm after completion.") }
        record?.completedAt = Date()
        record?.responseRequired = false
        try persist("completion_cancellation_verified")
      } else {
        let previous = record?.activeAlarmID ?? record?.id
        let replacement = UUID()
        let target = Date(timeIntervalSince1970: ceil(Date().timeIntervalSince1970) + 60)
        record?.activeAlarmID = replacement
        record?.activeDeadline = target
        try persist("patient_response: yes_i_will; snooze_registration_requested: \(replacement)")
        try await installAlarm(id: replacement, at: target)
        if let previous, try manager.alarms.contains(where: { $0.id == previous }) {
          try manager.cancel(id: previous)
        }
        record?.responseRequired = false
        try persist("patient_snooze_registration_verified")
      }
    } catch {
      errorMessage = "Response not safely finished: \(error.localizedDescription)"
      try? persist("response_failed: \(error.localizedDescription)")
    }
  }

  func cancel() {
    guard let alarm else { return }
    do {
      try manager.cancel(id: alarm.id)
      guard try !manager.alarms.contains(where: { $0.id == alarm.id }) else {
        throw Failure("The alarm still appears in the OS inventory.")
      }
      record?.responseRequired = false
      record?.completedAt = Date()
      try persist("test_cancelled_without_medication_response")
      refresh()
    } catch { errorMessage = error.localizedDescription }
  }

  private func apply(_ alarms: [Alarm]) {
    responseRequired = record?.responseRequired == true
    deadline = record?.activeDeadline ?? record?.deadline
    let next = alarms.first { $0.id == (record?.activeAlarmID ?? record?.id) }
    if next?.state != alarm?.state {
      // Observation time is NOT a delivery receipt or the time sound began.
      try? persist("os_state_observed: \(next.map { String(describing: $0.state) } ?? "absent")")
    }
    alarm = next
    updateReport()
  }

  private func persist(_ event: String) throws {
    let entry = "\(Date().formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))) \(event)"
    record?.observations.append(entry)
    if let record {
      try JSONEncoder().encode(record).write(to: storageURL,
        options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    logger.info("\(entry, privacy: .public)")
    updateReport()
  }

  private func updateReport() {
    guard let record else { return }
    report = """
    MediNag AlarmKit phone proof of concept
    Build: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")
    OS: \(ProcessInfo.processInfo.operatingSystemVersionString)
    Alarm ID: \(record.id)
    Requested at: \(record.requestedAt.ISO8601Format())
    Exact deadline: \(record.deadline.ISO8601Format())
    Active alarm: \((record.activeAlarmID ?? record.id).uuidString)
    Active deadline: \((record.activeDeadline ?? record.deadline).ISO8601Format())
    Response required: \(record.responseRequired == true)
    Registered at: \(record.registeredAt?.ISO8601Format() ?? "not confirmed")
    Live Activities allowed: \(ActivityAuthorizationInfo().areActivitiesEnabled)
    These observations do not prove audible delivery. Add the time you first heard the alarm, Focus/silent settings, and what you tapped.
    \(record.observations.joined(separator: "\n"))
    """
  }

  struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
  }
}

struct PrototypeView: View {
  @ObservedObject var model: PrototypeModel

  var body: some View {
    NavigationStack {
      if model.responseRequired {
        VStack(spacing: 24) {
          Button("Yes, I did") { Task { await model.respond(didTake: true) } }
            .accessibilityIdentifier("response-yes-i-did")
          Button("Yes, I will") { Task { await model.respond(didTake: false) } }
            .accessibilityIdentifier("response-yes-i-will")
          if let error = model.errorMessage {
            Text(error).foregroundStyle(.red).accessibilityIdentifier("alarm-error")
          }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(model.busy)
        .padding(24)
        .navigationBarBackButtonHidden()
      } else {
      Form {
        Section {
          Text("Phone-only alarm experiment").font(.headline)
          Text("Not a medication scheduler. This build replaces the phone reminder app. Setting the first test clears its old phone alerts. Remove the old Watch app or turn the Watch off for this phone test.")
            .font(.footnote)
        }
        Section("Set the next alarm") {
          Stepper("In \(model.minutes) minute\(model.minutes == 1 ? "" : "s")", value: $model.minutes, in: 1...60)
            .accessibilityIdentifier("alarm-delay")
          Button(model.busy ? "Setting alarm…" : "Set test alarm") {
            Task { await model.schedule() }
          }
          .disabled(model.busy)
          .accessibilityIdentifier("set-test-alarm")
        }
        Section("OS registration") {
          Text(model.alarm == nil ? "No active test alarm" : "Alarm registered with iOS")
            .accessibilityIdentifier("alarm-registration")
          if let deadline = model.deadline {
            LabeledContent("Requested alarm time") {
              Text(deadline, format: .dateTime.hour().minute().second()).monospacedDigit()
            }
            .accessibilityIdentifier("alarm-deadline")
          }
          if let alarm = model.alarm {
            Text("OS state: \(String(describing: alarm.state))")
            Button(intent: StopAndRespondIntent(alarmID: alarm.id)) {
              Text("Stop and respond")
            }
            .disabled(model.busy)
            .accessibilityIdentifier("stop-and-respond")
            Button("Cancel test alarm", role: .destructive) { model.cancel() }
              .accessibilityIdentifier("cancel-test-alarm")
          }
          if let error = model.errorMessage { Text(error).foregroundStyle(.red).accessibilityIdentifier("alarm-error") }
        }
        Section {
          Text("Allow Alarms when asked. Then lock the phone. Stop arms a one-minute follow-up before asking you to respond in MediNag. Snooze repeats after one minute. No network or app refresh is needed at the deadline.")
          Text("Alarm permission: \(String(describing: model.authorization))")
          ShareLink("Share test report", item: model.report)
        }
      }
      .navigationTitle("MediNag Alarm PoC")
      .tint(.teal)
      }
    }
  }
}
