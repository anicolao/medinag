import MediNagCore
import SwiftUI

@main
struct MediNagWatchApp: App {
  @StateObject private var connection = CompanionSession()
  @Environment(\.scenePhase) private var scenePhase

  var body: some Scene {
    WindowGroup {
      WatchScheduleView(connection: connection)
        .tint(Color(red: 0.08, green: 0.45, blue: 0.42))
        .onChange(of: scenePhase) { _, phase in
          if phase == .active { Task { await connection.refreshOnActivation() } }
        }
    }
  }
}

struct WatchScheduleView: View {
  @ObservedObject var connection: CompanionSession

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          if let snapshot = connection.snapshot, snapshot.ready {
            Text(snapshot.administratorName + "’s schedule")
              .font(.headline).accessibilityIdentifier("watch-administrator")
            Text(snapshot.readinessMessage).font(.caption2).foregroundStyle(.secondary)
              .accessibilityIdentifier("watch-alarm-readiness")
            if let event = snapshot.events.first(where: { $0.status != .completed }) {
              TimelineView(.periodic(from: .now, by: 1)) { context in
                dose(event, snapshot: snapshot, at: context.date)
              }
            } else {
              Label("All doses complete", systemImage: "checkmark.circle")
                .accessibilityIdentifier("watch-all-complete")
            }
            ForEach(snapshot.events.filter { $0.status == .completed }.suffix(3)) { event in
              VStack(alignment: .leading) {
                Text(event.medicationName)
                Label("Completed", systemImage: "checkmark.circle")
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .font(.caption).foregroundStyle(.secondary)
              .accessibilityElement(children: .combine)
              .accessibilityIdentifier("watch-completed-\(event.id)")
            }
          } else {
            VStack(alignment: .leading, spacing: 12) {
              Image(systemName: "iphone.and.arrow.forward").font(.largeTitle)
              Text("Set up on iPhone").font(.headline).accessibilityIdentifier("watch-setup")
              Text("Sign in with Google and choose your schedule in MediNag on your paired iPhone.")
                .font(.caption)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("watch-setup-instructions")
          }
          if !connection.reachable {
            Label("iPhone disconnected", systemImage: "iphone.slash")
              .font(.caption).foregroundStyle(.orange).accessibilityIdentifier("watch-disconnected")
          }
          if !connection.notice.isEmpty {
            Text(connection.notice).font(.caption).accessibilityIdentifier("watch-notice")
          }
          if connection.busy {
            Text("Confirming with iPhone…").font(.caption).accessibilityIdentifier("watch-progress")
          }
          Button("Refresh from iPhone", systemImage: "arrow.clockwise") {
            Task { await connection.refresh() }
          }
          .accessibilityIdentifier("watch-refresh")
          .disabled(connection.busy)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
      }
      .accessibilityIdentifier("watch-content")
      .navigationTitle("MediNag")
    }
  }

  private func dose(_ event: MedicationEvent, snapshot: CompanionSnapshot, at date: Date) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(event.medicationName).font(.headline).accessibilityIdentifier("watch-dose-name")
      Text(displayTime(event))
      .font(.title3).accessibilityIdentifier("watch-dose-time")
      Text(event.status == .snoozed ? "Snoozed · \(event.snoozeCount)" : "Pending")
        .font(.caption).accessibilityIdentifier("watch-dose-status")
      if snapshot.canRespond(to: event, at: date) {
        Text("Have you taken this dose?").font(.caption)
        responseButton("Yes, I did", response: .yesIDid, event: event, id: "watch-yes-i-did")
        responseButton("Yes, I will", response: .yesIWill, event: event, id: "watch-yes-i-will")
      } else if event.status == .snoozed {
        Text(event.snoozeCount < snapshot.maximumReminderCount
          ? "Next reminder after \(snapshot.snoozeMinutes) minutes."
          : "The configured reminder limit has been reached.").font(.caption2)
      } else {
        Text("Your paired iPhone owns this alarm.").font(.caption2).foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func responseButton(_ title: String, response: DoseResponse, event: MedicationEvent, id: String) -> some View {
    Button(title) { Task { await connection.respond(response, to: event) } }
      .buttonStyle(.bordered).tint(.teal)
      .disabled(!connection.reachable || connection.busy)
      .accessibilityIdentifier(id)
  }

  private func displayTime(_ event: MedicationEvent) -> String {
    var format = Date.FormatStyle(date: .omitted, time: .shortened)
    format.timeZone = TimeZone(identifier: event.timeZone) ?? .current
    return event.scheduledTime.formatted(format)
  }
}
