import BackgroundTasks
import GoogleSignIn
import OSLog
import UIKit
import MediNagCore
@preconcurrency import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
  // One owner shared by background notification/WCSession launches and the UI.
  // Construct only after Firebase configuration, but before launch completes.
  lazy var viewModel: AppViewModel = {
    _ = FirebaseBootstrap.configure()
    return AppViewModel.make()
  }()
  static let reminderRefreshIdentifier = "org.boardgamescafe.medinag.reminder-refresh"
  static let reminderMaintenanceIdentifier = "org.boardgamescafe.medinag.reminder-maintenance"
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
    let configured = FirebaseBootstrap.configure()
    LocalNotificationScheduler.registerCategories()
    UNUserNotificationCenter.current().delegate = self
    if configured {
      _ = viewModel
      LocalAlertJournal.record("phone_response_handler_ready")
    }
    let registered = BGTaskScheduler.shared.register(
      forTaskWithIdentifier: Self.reminderRefreshIdentifier,
      using: Self.reminderRefreshQueue
    ) { task in
      Self.handleReminderRefresh(task)
    }
    let maintenanceRegistered = BGTaskScheduler.shared.register(
      forTaskWithIdentifier: Self.reminderMaintenanceIdentifier,
      using: Self.reminderRefreshQueue
    ) { task in Self.handleReminderRefresh(task) }
    Self.reminderRefreshRegistrationSucceeded = registered && maintenanceRegistered
    if !registered || !maintenanceRegistered {
      Self.logger.fault(
        "Could not register reminder maintenance background handlers."
      )
    }
    Self.scheduleReminderRefresh()

    if ProcessInfo.processInfo.arguments.contains("-e2e") {
      UIView.setAnimationsEnabled(false)
    }
    return true
  }

  static func scheduleReminderRefresh() {
    var preferred = Date(timeIntervalSinceNow: 15 * 60)
    if let cache = try? DurableAlertStorage.load(PatientAlertCache.self, name: "phone-plan.json") {
      #if E2E
        let timeline = E2ERuntime.notificationTimeline()
      #else
        let timeline = SystemNotificationTimeline()
      #endif
      let plan = ReminderPlan(events: cache.events, now: timeline.now,
        snoozeInterval: Double(cache.plan.snoozeIntervalMinutes * 60),
        repeatInterval: Double(cache.plan.repeatIntervalMinutes * 60))
      preferred = timeline.deliveryDate(for: ReminderRefreshPolicy.preferredDate(
        now: timeline.now, events: cache.events, coveredThrough: plan.coveredThrough))
    }
    let preferredDate = preferred
    let identifiers = [reminderRefreshIdentifier, reminderMaintenanceIdentifier]
    BGTaskScheduler.shared.getPendingTaskRequests { pending in
      for identifier in identifiers {
        if pending.contains(where: { $0.identifier == identifier
          && ($0.earliestBeginDate ?? .distantPast) <= preferredDate }) { continue }
        let candidate: BGTaskRequest
        if identifier == identifiers[0] {
          candidate = BGAppRefreshTaskRequest(identifier: identifier)
        } else {
          let maintenance = BGProcessingTaskRequest(identifier: identifier)
          maintenance.requiresNetworkConnectivity = false // Cached repair works offline.
          maintenance.requiresExternalPower = false
          candidate = maintenance
        }
        candidate.earliestBeginDate = preferredDate
        do {
          try BGTaskScheduler.shared.submit(candidate)
          LocalAlertJournal.record("background_refresh_requested", deadline: preferredDate,
            details: ["identifier": candidate.identifier])
        } catch {
          LocalAlertJournal.record("background_refresh_request_failed",
            details: ["identifier": candidate.identifier, "error": error.localizedDescription])
        }
      }
    }
  }

  private static func handleReminderRefresh(_ task: BGTask) {
    LocalAlertJournal.record("background_refresh_started", details: ["identifier": task.identifier])
    scheduleReminderRefresh()
    let work = Task {
      do {
        try await BackgroundReminderRefresh.run()
        LocalAlertJournal.record("background_refresh_finished", details: ["identifier": task.identifier])
        scheduleReminderRefresh()
        task.setTaskCompleted(success: true)
      } catch {
        LocalAlertJournal.record("background_refresh_failed", details: ["error": error.localizedDescription])
        task.setTaskCompleted(success: false)
      }
    }
    task.expirationHandler = {
      LocalAlertJournal.record("background_refresh_expired", details: ["identifier": task.identifier])
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
    LocalAlertJournal.record("foreground_presentation_callback", requestID: notification.request.identifier,
      details: ["systemDate": String(notification.date.timeIntervalSince1970)])
    completionHandler([.banner, .list, .sound])
    Task { await BackgroundReminderRefresh.refreshCachedQueue(reason: "foreground_notification") }
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
    let completion = NotificationCompletion(finish: completionHandler)
    Task { @MainActor in
      defer { completion.finish() }
      LocalAlertJournal.record("notification_action_callback", requestID: identifier,
        details: ["action": actionIdentifier])
      await viewModel.waitForLocalBoot()
      if await PhoneNotificationResponse.handle(response) { return }
      await BackgroundReminderRefresh.refreshCachedQueue(reason: "notification_open_or_dismiss")
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

private struct NotificationCompletion: @unchecked Sendable { let finish: () -> Void }
