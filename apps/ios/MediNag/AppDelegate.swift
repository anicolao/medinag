import BackgroundTasks
import GoogleSignIn
import UIKit
@preconcurrency import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
  static let reminderRefreshIdentifier = "org.boardgamescafe.medinag.reminder-refresh"

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    FirebaseBootstrap.configure()
    LocalNotificationScheduler.registerCategories()
    UNUserNotificationCenter.current().delegate = self
    BGTaskScheduler.shared.register(
      forTaskWithIdentifier: Self.reminderRefreshIdentifier,
      using: nil
    ) { task in
      guard let refreshTask = task as? BGAppRefreshTask else {
        task.setTaskCompleted(success: false)
        return
      }
      Self.handleReminderRefresh(refreshTask)
    }
    Self.scheduleReminderRefresh()

    if ProcessInfo.processInfo.arguments.contains("-e2e") {
      UIView.setAnimationsEnabled(false)
    }
    return true
  }

  static func scheduleReminderRefresh() {
    let request = BGAppRefreshTaskRequest(
      identifier: reminderRefreshIdentifier
    )
    request.earliestBeginDate = Date(timeIntervalSinceNow: 24 * 60 * 60)
    do {
      try BGTaskScheduler.shared.submit(request)
    } catch {
      // A foreground refresh still maintains coverage. The next lifecycle
      // transition retries this opportunistic request.
    }
  }

  private static func handleReminderRefresh(_ task: BGAppRefreshTask) {
    scheduleReminderRefresh()
    let work = Task {
      do {
        try await BackgroundReminderRefresh.run()
        task.setTaskCompleted(success: true)
      } catch {
        task.setTaskCompleted(success: false)
      }
    }
    task.expirationHandler = {
      work.cancel()
    }
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
    NotificationDeliveryLedger.record(
      identifier: response.notification.request.identifier
    )
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
