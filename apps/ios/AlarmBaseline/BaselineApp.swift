import ActivityKit
@preconcurrency import AlarmKit
import Combine
import Foundation
import OSLog
import SwiftUI
import UserNotifications

// This diagnostic binary deliberately has no Firebase, custom App Intent,
// WidgetKit extension, custom sound, countdown, snooze or automatic retries.
struct BaselineMetadata: AlarmMetadata {}

@main
struct BaselineApp: App {
  @StateObject private var model = BaselineModel()
  var body: some Scene {
    WindowGroup { BaselineView(model: model).task { await model.observe() } }
  }
}

@MainActor
final class BaselineModel: ObservableObject {
  @Published var target = Date(timeIntervalSince1970: (floor(Date().timeIntervalSince1970 / 60) + 2) * 60)
  @Published private(set) var prepared = false
  @Published private(set) var registered = false
  @Published private(set) var busy = false
  @Published private(set) var error: String?
  @Published private(set) var report = ""
  private let manager = AlarmManager.shared
  private let logger = Logger(subsystem: "org.boardgamescafe.medinag", category: "MinimalBaseline")
  private var record = Record()
  private var previous: [UUID: String] = [:]
  struct Record: Codable {
    var prepared = false
    var alarmID: UUID?
    var deadline: Date?
    var observations: [String] = []
  }
  private var file: URL {
    get throws {
      try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
        appropriateFor: nil, create: true).appendingPathComponent("minimal-baseline.json")
    }
  }
  init() {
    do {
      let url = try file
      if FileManager.default.fileExists(atPath: url.path) {
        record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: url))
        prepared = record.prepared
      }
      if let deadline = record.deadline { target = deadline }
      updateReport()
    } catch { self.error = "Diagnostic evidence could not be loaded: \(error.localizedDescription)" }
  }
  private func note(_ event: String) throws {
    let entry = "\(Date().formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))) \(event)"
    record.observations.append(entry)
    try JSONEncoder().encode(record).write(to: file,
      options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    logger.info("\(entry, privacy: .public)")
    updateReport()
  }
  private func updateReport() {
    report = """
    Minimal AlarmKit baseline — NOT medication protection
    Build: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")
    OS: \(ProcessInfo.processInfo.operatingSystemVersionString)
    Time zone: \(TimeZone.autoupdatingCurrent.identifier)
    Alarm ID: \(record.alarmID?.uuidString ?? "none")
    Fixed deadline: \(record.deadline?.ISO8601Format() ?? "none")
    Default sound; ordinary system Stop; no countdown, snooze, custom intents, widget extension, retries or Firebase.
    Observations are not sound/presentation receipts. Record the actual time heard/seen separately.
    \(record.observations.joined(separator: "\n"))
    """
  }
  func observe() async {
    for await alarms in manager.alarmUpdates {
      registered = alarms.contains { $0.id == record.alarmID }
      let next = Dictionary(uniqueKeysWithValues: alarms.map { ($0.id, String(describing: $0.state)) })
      do {
        for (id, state) in next where previous[id] != state {
          try note("os_state_observed \(id) \(state); not audible-delivery proof")
        }
        for id in previous.keys where next[id] == nil { try note("os_identifier_absent \(id)") }
      } catch { self.error = error.localizedDescription }
      previous = next
    }
  }
  func prepare() async {
    guard !busy else { return }
    busy = true; error = nil
    defer { busy = false }
    do {
      guard try await manager.requestAuthorization() == .authorized else {
        throw Failure("Allow MediNag alarms in Settings before testing.")
      }
      // Explicit user action; only alarms/notifications owned by MediNag.
      for alarm in try manager.alarms { try manager.cancel(id: alarm.id) }
      let notifications = UNUserNotificationCenter.current()
      notifications.removeAllPendingNotificationRequests()
      notifications.removeAllDeliveredNotifications()
      guard try manager.alarms.isEmpty, await notifications.pendingNotificationRequests().isEmpty else {
        throw Failure("Existing MediNag alarms have not all been cleared; do not start the comparison.")
      }
      record.alarmID = nil; record.deadline = nil; record.prepared = true
      try note("baseline_prepared_existing_MediNag_alarms_removed; no medication data changed")
      registered = false; prepared = true
    } catch { self.error = error.localizedDescription }
  }
  func arm() async {
    guard prepared, !busy else { return }
    busy = true; error = nil
    defer { busy = false }
    do {
      guard target.timeIntervalSinceNow > 5 else { throw Failure("Choose an alarm time at least five seconds in the future.") }
      guard manager.authorizationState == .authorized else { throw Failure("Alarm permission is disabled.") }
      for old in try manager.alarms { try manager.cancel(id: old.id) }
      let id = UUID(), deadline = target
      record.alarmID = id; record.deadline = deadline
      try note("registration_requested \(id) deadline=\(deadline.ISO8601Format())")
      let attributes = AlarmAttributes<BaselineMetadata>(
        presentation: AlarmPresentation(alert: AlarmPresentation.Alert(title: "MediNag baseline alarm")),
        metadata: nil, tintColor: .blue)
      _ = try await manager.schedule(id: id, configuration: AlarmManager.AlarmConfiguration(
        schedule: .fixed(deadline), attributes: attributes, sound: .default))
      let inventory = try manager.alarms
      guard inventory.count == 1, inventory[0].id == id, inventory[0].schedule == .fixed(deadline) else {
        throw Failure("The OS did not confirm exactly one alarm at the requested time.")
      }
      try note("one_fixed_alarm_verified; this does not prove delivery")
      registered = true
    } catch { self.error = error.localizedDescription; try? note("failure \(error.localizedDescription)") }
  }
  func cancel() {
    do {
      for alarm in try manager.alarms { try manager.cancel(id: alarm.id) }
      guard try manager.alarms.isEmpty else { throw Failure("An alarm remains registered.") }
      try note("all_MediNag_alarms_absent_after_user_cancellation")
      registered = false
    } catch { self.error = error.localizedDescription }
  }
  struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
  }
}

struct BaselineView: View {
  @ObservedObject var model: BaselineModel
  var body: some View {
    NavigationStack {
      Form {
        Section("Diagnostic build — medication scheduling is OFF") {
          Text("This replaces the patient app. Preparation clears its existing phone alarms. Firebase medication records are not changed. Finish/cancel any separate Alarm Lab run and keep the Watch off for this phone-only comparison.")
        }
        Section("1. Clear previous MediNag alarms") {
          Button("Prepare baseline test") { Task { await model.prepare() } }
            .disabled(model.busy).accessibilityIdentifier("prepare-baseline")
          if model.prepared { Text("Ready for a single test alarm").accessibilityIdentifier("baseline-prepared") }
        }
        Section("2. Set one fixed-time alarm") {
          DatePicker("Alarm time", selection: $model.target, displayedComponents: [.date, .hourAndMinute])
          Button("Arm baseline alarm") { Task { await model.arm() } }
            .disabled(!model.prepared || model.busy).accessibilityIdentifier("arm-baseline")
          Text(model.registered ? "One alarm registered with iOS" : "No baseline alarm in OS inventory")
            .accessibilityIdentifier("baseline-inventory")
        }
        Section("3. Observe actual sound and UI") {
          Text("Set a Clock alarm two minutes later as a control. Lock the phone and note when each actually sounds. Stop here is the ordinary system Stop; it does not open MediNag or record medication taken. Repeat after a longer idle period before adding features.")
          ShareLink("Share baseline report", item: model.report)
          if let error = model.error { Text(error).foregroundStyle(.red) }
        }
      }.navigationTitle("MediNag Baseline")
        .toolbar {
          ToolbarItem(placement: .topBarTrailing) {
            Button("Cancel test", role: .destructive) { model.cancel() }
              .accessibilityIdentifier("cancel-baseline")
          }
        }
    }
  }
}
