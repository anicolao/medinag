import SwiftUI
import UIKit

@main
struct MediNagApp: App {
  @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
        .statusBarHidden(ProcessInfo.processInfo.arguments.contains("-e2e"))
    }
  }
}
