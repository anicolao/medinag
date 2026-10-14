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

  func applicationDidBecomeActive(_ application: UIApplication) {
    Task {
      let center = UNUserNotificationCenter.current()
      let handledIdentifiers = NotificationDeliveryLedger.identifiers
      let delivered = await center.deliveredNotifications()
        .filter {
          $0.request.identifier.hasPrefix("medinag.dose.")
            && !handledIdentifiers.contains($0.request.identifier)
        }
        .sorted { $0.date > $1.date }
      guard let notification = delivered.first else { return }
      await Self.route(
        notification,
        actionIdentifier: UNNotificationDefaultActionIdentifier,
        center: center,
        removeFromNotificationCenter: true
      )
    }
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    await Self.route(
      notification,
      actionIdentifier: UNNotificationDefaultActionIdentifier,
      center: center,
      removeFromNotificationCenter: false
    )
    return [.banner, .list, .sound]
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse
  ) async {
    let identifier = response.notification.request.identifier
    let alreadyHandled = NotificationDeliveryLedger.identifiers.contains(identifier)
    if
      alreadyHandled,
      response.actionIdentifier == UNNotificationDefaultActionIdentifier
    {
      center.removeDeliveredNotifications(withIdentifiers: [identifier])
      return
    }
    await Self.route(
      response.notification,
      actionIdentifier: response.actionIdentifier,
      center: center,
      removeFromNotificationCenter: true
    )
  }

  private nonisolated static func route(
    _ notification: UNNotification,
    actionIdentifier: String,
    center: UNUserNotificationCenter,
    removeFromNotificationCenter: Bool
  ) async {
    let identifier = notification.request.identifier
    guard identifier.hasPrefix("medinag.dose.") else { return }
    guard let interaction = NotificationInteraction(
      actionIdentifier: actionIdentifier,
      userInfo: notification.request.content.userInfo
    ) else { return }
    NotificationDeliveryLedger.record(identifier: identifier)
    if removeFromNotificationCenter {
      center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }
    await NotificationResponseRouter.shared.route(interaction)
  }
}
