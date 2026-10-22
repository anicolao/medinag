import BackgroundTasks
import GoogleSignIn
import OSLog
import UIKit
@preconcurrency import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
  static let reminderRefreshIdentifier = "org.boardgamescafe.medinag.reminder-refresh"
  static let reminderRefreshQueue = DispatchQueue.main
  static private(set) var reminderRefreshRegistrationSucceeded: Bool?
  private static let logger = Logger(
    subsystem: "org.boardgamescafe.medinag",
    category: "BackgroundRefresh"
  )

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    FirebaseBootstrap.configure()
    LocalNotificationScheduler.registerCategories()
    UNUserNotificationCenter.current().delegate = self
    let registered = BGTaskScheduler.shared.register(
      forTaskWithIdentifier: Self.reminderRefreshIdentifier,
      using: Self.reminderRefreshQueue
    ) { task in
      guard let refreshTask = task as? BGAppRefreshTask else {
        task.setTaskCompleted(success: false)
        return
      }
      Self.handleReminderRefresh(refreshTask)
    }
    Self.reminderRefreshRegistrationSucceeded = registered
    if !registered {
      Self.logger.fault(
        "Could not register the daily reminder refresh task."
      )
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
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (
      UNNotificationPresentationOptions
    ) -> Void
  ) {
    // Keep the explicit callback delegate overloads. The async protocol bridge
    // aborted inside UIKit after notification taps on iOS 18.1.
    completionHandler([.banner, .list, .sound])
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let identifier = response.notification.request.identifier
    let actionIdentifier = response.actionIdentifier
    let interaction = NotificationInteraction(
      actionIdentifier: response.actionIdentifier,
      userInfo: response.notification.request.content.userInfo
    )
    // Release the system response immediately, then perform app routing on the
    // main actor. This avoids holding UIKit's completion callback across a hop.
    completionHandler()
    Task { @MainActor in
      let newlyClaimed = NotificationDeliveryLedger.claim(identifier: identifier)
      if
        let interaction,
        newlyClaimed || actionIdentifier != UNNotificationDefaultActionIdentifier
      {
        NotificationResponseRouter.shared.route(interaction)
      }
      center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }
  }
}
