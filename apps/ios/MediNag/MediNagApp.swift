import SwiftUI

@main
struct MediNagApp: App {
  @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var viewModel = AppViewModel.make()

  var body: some Scene {
    WindowGroup {
      ContentView(viewModel: viewModel)
        .preferredColorScheme(.light)
    }
  }
}
