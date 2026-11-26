import ActivityKit
@preconcurrency import AlarmKit
import Combine
import OSLog
import SwiftUI
import UserNotifications

@main
struct PrototypeApp: App {
  @StateObject private var model = PrototypeModel()
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
  @Published var minutes = 1
  @Published private(set) var busy = false
  @Published private(set) var alarm: Alarm?
  @Published private(set) var deadline: Date?
  @Published private(set) var authorization = AlarmManager.shared.authorizationState
  @Published private(set) var errorMessage: String?
  @Published private(set) var report: String = "No test scheduled."
  private let manager = AlarmManager.shared
  private let defaults = UserDefaults.standard
  private let logger = Logger(subsystem: "org.boardgamescafe.medinag", category: "AlarmPrototype")
  private let key = "medinag.alarm-prototype.record"
  private let cleanupKey = "medinag.alarm-prototype.cleaned-legacy-phone-queue"
  private var record: Record?

  struct Record: Codable {
    let id: UUID
    let requestedAt: Date
    let deadline: Date
    var registeredAt: Date?
    var observations: [String]
  }

  init() {
    if let data = defaults.data(forKey: key) {
      record = try? JSONDecoder().decode(Record.self, from: data)
    }
    deadline = record?.deadline
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
      if let existing = record, try manager.alarms.contains(where: { $0.id == existing.id }) {
        try manager.cancel(id: existing.id)
      }
      alarm = nil
      let requested = Date()
      let target = Date(timeIntervalSince1970: ceil(requested.timeIntervalSince1970) + Double(minutes * 60))
      let id = UUID()
      record = Record(id: id, requestedAt: requested, deadline: target, observations: [])
      deadline = target
      persist("schedule_requested")
      let presentation = AlarmPresentation(
        alert: AlarmPresentation.Alert(title: "MediNag alarm test",
          secondaryButton: AlarmButton(text: "Snooze 1 min", textColor: .white, systemImageName: "zzz"),
          secondaryButtonBehavior: .countdown),
        countdown: AlarmPresentation.Countdown(title: "MediNag alarm test"))
      let attributes = AlarmAttributes(presentation: presentation,
        metadata: PrototypeMetadata(requestedAt: requested, deadline: target), tintColor: .teal)
      let configuration = AlarmManager.AlarmConfiguration(
        countdownDuration: Alarm.CountdownDuration(preAlert: target.timeIntervalSinceNow, postAlert: 60),
        schedule: .fixed(target), attributes: attributes,
        sound: .named("MediNagAlarm.caf"))
      _ = try await manager.schedule(id: id, configuration: configuration)
      let inventory = try manager.alarms
      guard inventory.count == 1, let installed = inventory.first, installed.id == id,
        installed.schedule == .fixed(target) else {
        throw Failure("The OS did not confirm the exact requested alarm. Do not rely on this test.")
      }
      record?.registeredAt = Date()
      persist("registration_verified")
      apply(inventory)
    } catch {
      errorMessage = error.localizedDescription
      persist("schedule_failed: \(error.localizedDescription)")
      refresh()
    }
  }

  func cancel() {
    guard let alarm else { return }
    do {
      try manager.cancel(id: alarm.id)
      guard try !manager.alarms.contains(where: { $0.id == alarm.id }) else {
        throw Failure("The alarm still appears in the OS inventory.")
      }
      persist("cancellation_verified")
      refresh()
    } catch { errorMessage = error.localizedDescription }
  }

  private func apply(_ alarms: [Alarm]) {
    let next = alarms.first { $0.id == record?.id }
    if next?.state != alarm?.state {
      // Observation time is NOT a delivery receipt or the time sound began.
      persist("os_state_observed: \(next.map { String(describing: $0.state) } ?? "absent")")
    }
    alarm = next
    updateReport()
  }

  private func persist(_ event: String) {
    let entry = "\(Date().formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))) \(event)"
    record?.observations.append(entry)
    if let record, let data = try? JSONEncoder().encode(record) { defaults.set(data, forKey: key) }
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
            Button("Cancel test alarm", role: .destructive) { model.cancel() }
              .accessibilityIdentifier("cancel-test-alarm")
          }
          if let error = model.errorMessage { Text(error).foregroundStyle(.red).accessibilityIdentifier("alarm-error") }
        }
        Section {
          Text("Allow Alarms when asked. Then lock the phone. Try Sleep/Do Not Disturb and silent mode. iOS owns the sound and Stop control; Snooze repeats after 1 minute. No network or app refresh is needed at the deadline.")
          Text("Alarm permission: \(String(describing: model.authorization))")
          ShareLink("Share test report", item: model.report)
        }
      }
      .navigationTitle("MediNag Alarm PoC")
      .tint(.teal)
    }
  }
}
