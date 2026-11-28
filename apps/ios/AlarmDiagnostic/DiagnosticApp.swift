import ActivityKit
import AppIntents
@preconcurrency import AlarmKit
import Combine
import Foundation
import OSLog
import SwiftUI

/// A deliberately separate, user-operated physical experiment. These are
/// labeled test alarms, not medication fixtures or a production E2E substitute.
@main
struct DiagnosticApp: App {
  @StateObject private var model = DiagnosticModel.shared
  @Environment(\.scenePhase) private var phase
  var body: some Scene {
    WindowGroup {
      DiagnosticView(model: model)
        .task { await model.observe() }
        .onChange(of: phase) { _, value in
          model.note("scene_phase", String(describing: value))
        }
    }
  }
}

@MainActor
final class DiagnosticModel: ObservableObject {
  static let shared = DiagnosticModel()
  enum Mode: String, Codable, CaseIterable, Identifiable {
    case ordinary, background, foreground
    var id: String { rawValue }
    var title: String {
      switch self {
      case .ordinary: "A — Ordinary system Stop"
      case .background: "B — Background Stop intent"
      case .foreground: "C — Stop and open app"
      }
    }
  }
  struct Entry: Codable {
    let id: UUID
    let deadline: Date
  }
  struct Observation: Codable {
    let time: Date
    let kind: String
    let detail: String
  }
  struct Run: Codable {
    let id: UUID
    let mode: Mode
    let started: Date
    let systemVersion: String
    let timeZone: String
    let intervalMinutes: Int
    let alarms: [Entry]
    var observations: [Observation] = []
    var finished: Bool = false
  }
  @Published var mode = Mode.ordinary
  @Published private(set) var runs: [Run] = []
  @Published private(set) var busy = false
  @Published private(set) var error: String?
  @Published private(set) var responseRequired = false
  @Published private(set) var installedCount = 0
  @Published private(set) var report = "No experiment yet."
  private let manager = AlarmManager.shared
  private let logger = Logger(subsystem: "org.boardgamescafe.medinag.alarmlab", category: "PhysicalExperiment")
  private var states: [UUID: String] = [:]
  var active: Run? { runs.last.flatMap { $0.finished ? nil : $0 } }
  private static var file: URL {
    get throws {
      try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
        appropriateFor: nil, create: true).appendingPathComponent("alarm-lab.json")
    }
  }
  init() {
    if let url = try? Self.file, let data = try? Data(contentsOf: url),
      let saved = try? JSONDecoder().decode([Run].self, from: data) { runs = saved }
    updateReport()
  }
  func note(_ kind: String, _ detail: String = "") {
    guard !runs.isEmpty else { return }
    runs[runs.count - 1].observations.append(.init(time: Date(), kind: kind, detail: detail))
    logger.info("\(kind, privacy: .public) \(detail, privacy: .public)")
    do { try JSONEncoder().encode(runs).write(to: Self.file,
      options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
    catch { self.error = "Could not save diagnostic evidence: \(error.localizedDescription)" }
    updateReport()
  }
  private func updateReport() {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(runs), let text = String(data: data, encoding: .utf8) { report = text }
  }
  func observe() async {
    for await alarms in manager.alarmUpdates {
      let next = Dictionary(uniqueKeysWithValues: alarms.map { ($0.id, String(describing: $0.state)) })
      installedCount = alarms.count
      for (id, value) in next where states[id] != value {
        note("os_state_observed", "\(id) \(value); NOT audible-delivery proof")
      }
      for id in states.keys where next[id] == nil { note("os_identifier_absent", id.uuidString) }
      states = next
    }
  }
  func schedule() async {
    guard !busy, active == nil else { return }
    busy = true; error = nil; responseRequired = false
    defer { busy = false }
    do {
      guard try await manager.requestAuthorization() == .authorized else {
        throw Failure("Allow Alarms for MediNag Alarm Lab in Settings.")
      }
      // AlarmManager is scoped to this separate bundle, never the patient app.
      for alarm in try manager.alarms { try manager.cancel(id: alarm.id) }
      let first = Date(timeIntervalSince1970: ceil(Date().timeIntervalSince1970) + 60)
      let entries = (0...2).map { Entry(id: UUID(), deadline: first.addingTimeInterval(Double($0) * 180)) }
      runs.append(.init(id: UUID(), mode: mode, started: Date(),
        systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
        timeZone: TimeZone.autoupdatingCurrent.identifier, intervalMinutes: 3, alarms: entries))
      note("run_started", mode.rawValue)
      for (index, entry) in entries.enumerated() {
        let stop: (any LiveActivityIntent)?
        switch mode {
        case .ordinary: stop = nil
        case .background: stop = DiagnosticBackgroundStop(alarmID: entry.id)
        case .foreground: stop = DiagnosticForegroundStop(alarmID: entry.id)
        }
        let attributes = AlarmAttributes(presentation: AlarmPresentation(
          alert: AlarmPresentation.Alert(title: "Alarm Lab test",
            secondaryButton: AlarmButton(text: "Snooze", textColor: .white, systemImageName: "zzz"),
            secondaryButtonBehavior: .countdown),
          countdown: AlarmPresentation.Countdown(title: "Alarm Lab test")),
          metadata: PrototypeMetadata(requestedAt: Date(), deadline: entry.deadline,
            title: "\(mode.rawValue) test \(index + 1) of 3"), tintColor: .teal)
        note("registration_requested", "\(entry.id) deadline=\(entry.deadline.ISO8601Format())")
        _ = try await manager.schedule(id: entry.id, configuration: AlarmManager.AlarmConfiguration(
          countdownDuration: Alarm.CountdownDuration(preAlert: nil, postAlert: 300),
          schedule: .fixed(entry.deadline), attributes: attributes, stopIntent: stop,
          sound: .named("MediNagAlarm.caf")))
        guard try manager.alarms.contains(where: { $0.id == entry.id && $0.schedule == .fixed(entry.deadline) }) else {
          throw Failure("The OS did not confirm the exact diagnostic deadline.")
        }
        note("registration_verified", entry.id.uuidString)
      }
      note("all_three_verified", "No callback or interaction is needed to arm the follow-ups.")
      installedCount = try manager.alarms.count
    } catch { self.error = error.localizedDescription; note("failure", error.localizedDescription) }
  }
  func stopped(_ id: UUID, foreground: Bool) {
    note("stop_intent_received", id.uuidString)
    responseRequired = foreground
    // No scheduler, network or Firebase work. Only the supported execution mode
    // differs between B and C, isolating the foreground handoff.
    note("stop_intent_returning", foreground ? "foreground deferred" : "background")
  }
  func finish() {
    do {
      for alarm in try manager.alarms { try manager.cancel(id: alarm.id) }
      guard try manager.alarms.isEmpty else { throw Failure("Diagnostic alarms remain registered.") }
      installedCount = 0
      responseRequired = false
      if !runs.isEmpty { runs[runs.count - 1].finished = true }
      note("run_finished", "All Alarm Lab identifiers absent; patient app untouched.")
    } catch { self.error = error.localizedDescription; note("failure", error.localizedDescription) }
  }
  struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
  }
}

struct DiagnosticBackgroundStop: LiveActivityIntent {
  static let title: LocalizedStringResource = "Alarm Lab background Stop"
  static var supportedModes: IntentModes { [.background] }
  static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }
  @Parameter(title: "Alarm identifier") var identifier: String
  init() {}
  init(alarmID: UUID) { identifier = alarmID.uuidString }
  @MainActor func perform() async throws -> some IntentResult {
    if let id = UUID(uuidString: identifier) { DiagnosticModel.shared.stopped(id, foreground: false) }
    return .result()
  }
}

struct DiagnosticForegroundStop: LiveActivityIntent {
  static let title: LocalizedStringResource = "Alarm Lab Stop and open app"
  static var supportedModes: IntentModes { [.foreground(.deferred)] }
  static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }
  @Parameter(title: "Alarm identifier") var identifier: String
  init() {}
  init(alarmID: UUID) { identifier = alarmID.uuidString }
  @MainActor func perform() async throws -> some IntentResult {
    if let id = UUID(uuidString: identifier) { DiagnosticModel.shared.stopped(id, foreground: true) }
    return .result()
  }
}

struct DiagnosticView: View {
  @ObservedObject var model: DiagnosticModel
  var body: some View {
    NavigationStack {
      Form {
        Section("Physical test only — not medication") {
          Text("Separate app. Your MediNag schedule is not changed. Registration and OS states do not prove sound or presentation.")
        }
        if model.responseRequired {
          Section("Custom Stop opened the app") {
            Text("For this experiment, do not finish yet. Lock the phone again and leave both follow-ups untouched.")
          }
        }
        Section("Compare Stop behavior") {
          Picker("Mode", selection: $model.mode) {
            ForEach(DiagnosticModel.Mode.allCases) { Text($0.title).tag($0) }
          }.disabled(model.active != nil || model.busy)
          Button("Arm three test alarms") { Task { await model.schedule() } }
            .disabled(model.active != nil || model.busy)
            .accessibilityIdentifier("arm-diagnostic-alarms")
        }
        if let run = model.active {
          Section("Expected times — note actual sound/UI yourself") {
            Text("\(model.installedCount) OS alarms registered")
              .accessibilityIdentifier("diagnostic-inventory")
            ForEach(Array(run.alarms.enumerated()), id: \.element.id) { index, alarm in
              LabeledContent(index == 0 ? "First: tap Stop" : "Follow-up: do not tap") {
                Text(alarm.deadline, format: .dateTime.hour().minute().second()).monospacedDigit()
                  .accessibilityIdentifier("diagnostic-deadline-\(index)")
              }
            }
          }
        }
        Section {
          Text("Start with A. Allow Alarms, lock the phone, and tap Stop on the first alarm. Lock again; do not touch the two follow-ups. Wait until the last expected time, then finish. Repeat with C under the same phone/Focus/Watch conditions. B isolates intent execution if A and C differ. Do not use Snooze in these runs.")
          ShareLink("Share diagnostic report", item: model.report)
          if let error = model.error { Text(error).foregroundStyle(.red) }
        }
      }.navigationTitle("MediNag Alarm Lab")
        .toolbar {
          ToolbarItem(placement: .topBarTrailing) {
            Button("Finish test", role: .destructive) { model.finish() }
              .accessibilityIdentifier("finish-diagnostic-test")
          }
        }
    }
  }
}
