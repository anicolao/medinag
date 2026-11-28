import ActivityKit
import AlarmKit
import SwiftUI
import WidgetKit

@main
struct PrototypeWidgets: WidgetBundle {
  var body: some Widget { PrototypeLiveActivity() }
}

struct PrototypeLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: AlarmAttributes<PrototypeMetadata>.self) { context in
      HStack(spacing: 16) {
        Image(systemName: "alarm.fill").font(.largeTitle)
        VStack(alignment: .leading, spacing: 6) {
          Text(context.attributes.metadata?.title ?? "MediNag alarm test").font(.headline)
          countdown(context.state)
        }
        Spacer()
      }
      .padding()
      .activityBackgroundTint(Color(red: 0.02, green: 0.22, blue: 0.23))
      .activitySystemActionForegroundColor(.white)
      .foregroundStyle(.white)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) { Image(systemName: "alarm.fill") }
        DynamicIslandExpandedRegion(.trailing) { countdown(context.state) }
        DynamicIslandExpandedRegion(.bottom) { Text(context.attributes.metadata?.title ?? "MediNag alarm test") }
      } compactLeading: {
        Image(systemName: "alarm.fill")
      } compactTrailing: {
        countdown(context.state).frame(maxWidth: 64)
      } minimal: {
        Image(systemName: "alarm.fill")
      }
      .keylineTint(.teal)
    }
  }

  @ViewBuilder
  private func countdown(_ state: AlarmPresentationState) -> some View {
    switch state.mode {
    case .countdown(let value):
      Text(timerInterval: value.startDate...max(value.startDate, value.fireDate), countsDown: true)
        .monospacedDigit()
    case .paused:
      Text("Paused")
    case .alert:
      Text("Alarm")
    @unknown default:
      Text("Alarm")
    }
  }
}
