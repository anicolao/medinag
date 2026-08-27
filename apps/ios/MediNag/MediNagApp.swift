import SwiftUI
import UIKit

@main
struct MediNagApp: App {
  @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @Environment(\.scenePhase) private var scenePhase
  @StateObject private var viewModel = AppViewModel.make()

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
          #if E2E
            if phase == .background && E2ERuntime.notificationAccelerationEnabled {
              LocalNotificationScheduler.deliverAcceleratedNotification()
            }
          #endif
        }
    }
  }
}
