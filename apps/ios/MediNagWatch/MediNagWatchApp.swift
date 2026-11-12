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
        .onChange(of: scenePhase, initial: true) { _, phase in
          if phase == .active { Task { await connection.refreshOnActivation() } }
          else if phase == .background { connection.requestBackgroundMaintenance() }
        }
    }
    .backgroundTask(.watchConnectivity) {
      await connection.finishBackgroundTransfers()
    }
    .backgroundTask(.appRefresh("medinag.queue-refresh")) {
      await connection.refreshInBackground()
    }
  }
}

/// One dose, one time, two equal choices. No dashboard on the wrist.
struct WatchScheduleView: View {
  @ObservedObject var connection: CompanionSession

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      VStack(spacing: 12) {
        if let snapshot = connection.presentationSnapshot, snapshot.ready {
          if let event = snapshot.nextEvent(at: context.date) {
            let now = snapshot.logicalDate.addingTimeInterval(
              context.date.timeIntervalSince(snapshot.realDate) / snapshot.clockScale)
            if event.scheduledTime <= now && snapshot.nextReminder(for: event) <= now {
              responseButton("Yes, I did", response: .yesIDid, event: event, id: "watch-yes-i-did")
              responseButton("Yes, I will", response: .yesIWill, event: event, id: "watch-yes-i-will")
            } else {
              Text(event.medicationName).font(.headline)
                .accessibilityIdentifier("watch-dose-name")
              Text(displayTime(event.scheduledTime, timeZone: event.timeZone, now: now))
                .font(.body)
                .accessibilityIdentifier("watch-dose-time")
              if snapshot.canRespond(to: event, at: context.date) {
                responseButton("Yes, I did", response: .yesIDid, event: event, id: "watch-yes-i-did")
              }
            }
          } else {
            Text("No upcoming dose").accessibilityIdentifier("watch-no-upcoming-dose")
          }
        } else {
          Text("Set up on iPhone").accessibilityIdentifier("watch-setup")
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .padding(.horizontal, 8)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("watch-content")
      .task(id: connection.presentationSnapshot?.nextEvent(at: context.date)?.id) {
        await connection.doseWindowDidChange()
      }
    }
  }

  private func responseButton(_ title: String, response: DoseResponse, event: MedicationEvent, id: String) -> some View {
    Button(title) { Task { await connection.respond(response, to: event) } }
      .buttonStyle(.bordered).tint(.teal)
      .frame(maxWidth: .infinity)
      .accessibilityIdentifier(id)
  }

  private func displayTime(_ date: Date, timeZone: String, now: Date) -> String {
    let zone = TimeZone(identifier: timeZone) ?? .current
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    if calendar.isDate(date, inSameDayAs: now) {
      var format = Date.FormatStyle(date: .omitted, time: .shortened)
      format.timeZone = zone
      return date.formatted(format)
    }
    var format = Date.FormatStyle.dateTime.month(.abbreviated).day().hour().minute()
    format.timeZone = zone
    return date.formatted(format)
  }
}
