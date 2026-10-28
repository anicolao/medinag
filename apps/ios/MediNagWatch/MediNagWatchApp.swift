import MediNagCore
import SwiftUI

@main
struct MediNagWatchApp: App {
  @StateObject private var connection = CompanionSession()
  @Environment(\.scenePhase) private var scenePhase

  var body: some Scene {
    WindowGroup {
      WatchScheduleView(connection: connection)
        .tint(.teal)
        .onChange(of: scenePhase) { _, phase in
          if phase == .active { Task { await connection.refreshOnActivation() } }
        }
    }
    .backgroundTask(.watchConnectivity) {
      await connection.finishBackgroundTransfers()
    }
  }
}

/// One dose, one time, two equal choices. No dashboard on the wrist.
struct WatchScheduleView: View {
  @ObservedObject var connection: CompanionSession

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      VStack(spacing: 8) {
        if let snapshot = connection.snapshot, snapshot.ready {
          if let event = snapshot.nextEvent {
            Text(event.medicationName).font(.headline).lineLimit(2)
              .accessibilityIdentifier("watch-dose-name")
            Text(displayTime(snapshot.nextReminder(for: event), timeZone: event.timeZone))
              .font(.title3).accessibilityIdentifier("watch-dose-time")
            if snapshot.canRespond(to: event, at: context.date) {
              responseButton("Yes, I did", response: .yesIDid, event: event, id: "watch-yes-i-did")
              responseButton("Yes, I will", response: .yesIWill, event: event, id: "watch-yes-i-will")
            } else {
              Text("Next dose").font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("watch-next-dose")
            }
          } else {
            Text("All doses complete").accessibilityIdentifier("watch-all-complete")
          }
        } else {
          Text("Set up on iPhone").accessibilityIdentifier("watch-setup")
        }
        if connection.busy || connection.hasPendingResponse {
          Text("Waiting for confirmation…").font(.caption2)
            .accessibilityIdentifier("watch-progress")
        } else if !connection.notice.isEmpty {
          Text(connection.notice).font(.caption2).lineLimit(3)
            .accessibilityIdentifier("watch-notice")
        } else if !connection.reachable {
          Text("iPhone disconnected").font(.caption2).foregroundStyle(.secondary)
            .accessibilityIdentifier("watch-disconnected")
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .padding(.horizontal, 8)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("watch-content")
      .accessibilityValue(connection.snapshot?.nextEvent.map {
        "\($0.id)|\($0.status.rawValue)|\($0.snoozeCount)"
      } ?? "no-current-dose")
    }
  }

  private func responseButton(_ title: String, response: DoseResponse, event: MedicationEvent, id: String) -> some View {
    Button(title) { Task { await connection.respond(response, to: event) } }
      .buttonStyle(.bordered).tint(.teal)
      .frame(maxWidth: .infinity)
      .disabled(connection.busy || connection.hasPendingResponse)
      .accessibilityIdentifier(id)
  }

  private func displayTime(_ date: Date, timeZone: String) -> String {
    var format = Date.FormatStyle(date: .abbreviated, time: .shortened)
    format.timeZone = TimeZone(identifier: timeZone) ?? .current
    return date.formatted(format)
  }
}
