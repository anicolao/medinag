import SwiftUI
import UIKit

@main
struct MediNagApp: App {
  @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var viewModel = AppViewModel.make()
  @Environment(\.scenePhase) private var scenePhase

  init() {
    #if E2E
      UIView.setAnimationsEnabled(false)
    #endif
  }

  var body: some Scene {
    WindowGroup {
      ContentView(viewModel: viewModel)
        .preferredColorScheme(.light)
        .onChange(of: scenePhase) { _, phase in
          if phase == .active {
            Task { await viewModel.refreshOnForeground() }
          } else if phase == .background {
            AppDelegate.scheduleReminderRefresh()
          }
        }
    }
  }
}
