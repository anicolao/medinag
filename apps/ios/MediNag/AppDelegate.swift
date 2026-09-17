import GoogleSignIn
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

  func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    GIDSignIn.sharedInstance.handle(url)
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
    center.removeDeliveredNotifications(
      withIdentifiers: [response.notification.request.identifier]
    )
    let content = response.notification.request.content
    guard
      let eventID = content.userInfo[
        MediNagNotification.eventID
      ] as? String,
      let medicationName = content.userInfo[
        MediNagNotification.medicationName
      ] as? String,
      let reminderTimestamp = content.userInfo[
        MediNagNotification.reminderTime
      ] as? TimeInterval,
      let reminderNumber = content.userInfo[
        MediNagNotification.reminderNumber
      ] as? Int
    else {
      return
    }
    await NotificationResponseRouter.shared.route(
      actionIdentifier: response.actionIdentifier,
      eventID: eventID,
      medicationName: medicationName,
      reminderTime: Date(timeIntervalSince1970: reminderTimestamp),
      reminderNumber: reminderNumber
    )
  }
}
