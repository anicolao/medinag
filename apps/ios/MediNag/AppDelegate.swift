import UIKit
@preconcurrency import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    FirebaseBootstrap.configure()
    LocalNotificationScheduler.registerCategories()
    UNUserNotificationCenter.current().delegate = self

    if ProcessInfo.processInfo.arguments.contains("-e2e") {
      UIView.setAnimationsEnabled(false)
    }
    return true
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    [.banner, .list, .sound]
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse
  ) async {
    guard
      let eventID = response.notification.request.content.userInfo[
        MediNagNotification.eventID
      ] as? String
    else {
      return
    }
    await NotificationResponseRouter.shared.route(
      actionIdentifier: response.actionIdentifier,
      eventID: eventID
    )
  }
}
