import Foundation
import MediNagCore
@preconcurrency import UserNotifications

enum MediNagNotification {
  static let category = "MEDINAG_NAG_CATEGORY"
  static let yesIWill = "ACTION_YES_I_WILL"
  static let yesIDid = "ACTION_YES_I_DID"
  static let eventID = "medinagEventID"
}

struct NotificationResponse: Sendable {
  let response: DoseResponse
  let eventID: String
}

@MainActor
final class NotificationResponseRouter {
  static let shared = NotificationResponseRouter()

  var handler: ((NotificationResponse) -> Void)?

  private init() {}

  func route(actionIdentifier: String, eventID: String) {
    let response: DoseResponse
    switch actionIdentifier {
    case MediNagNotification.yesIWill:
      response = .yesIWill
    case MediNagNotification.yesIDid:
      response = .yesIDid
    default:
      return
    }
    handler?(.init(response: response, eventID: eventID))
  }
}

final class LocalNotificationScheduler: NotificationScheduling, @unchecked Sendable {
  private let center: UNUserNotificationCenter

  init(center: UNUserNotificationCenter = .current()) {
    self.center = center
  }

  static func registerCategories(
    center: UNUserNotificationCenter = .current()
  ) {
    let yesIWill = UNNotificationAction(
      identifier: MediNagNotification.yesIWill,
      title: "Yes, I will",
      options: [.foreground]
    )
    let yesIDid = UNNotificationAction(
      identifier: MediNagNotification.yesIDid,
      title: "Yes, I did",
      options: [.foreground]
    )
    let category = UNNotificationCategory(
      identifier: MediNagNotification.category,
      actions: [yesIWill, yesIDid],
      intentIdentifiers: [],
      options: [.customDismissAction]
    )
    center.setNotificationCategories([category])
  }

  func requestAuthorization() async throws -> Bool {
    try await center.requestAuthorization(options: [.alert, .badge, .sound])
  }

  func authorizationStatus() async -> UNAuthorizationStatus {
    await center.notificationSettings().authorizationStatus
  }

  func schedule(event: MedicationEvent) async throws {
    try await addNotification(for: event, at: event.scheduledTime)
  }

  func scheduleRepeat(for event: MedicationEvent, at date: Date) async throws {
    try await addNotification(for: event, at: date)
  }

  func cancel(eventID: String) async {
    center.removePendingNotificationRequests(
      withIdentifiers: [notificationIdentifier(eventID: eventID)]
    )
    center.removeDeliveredNotifications(
      withIdentifiers: [notificationIdentifier(eventID: eventID)]
    )
  }

  private func addNotification(
    for event: MedicationEvent,
    at date: Date
  ) async throws {
    // Never turn a missed medication time into an immediate, misleading first
    // reminder. Events must be scheduled ahead of time and fire at their
    // absolute medication or snooze-expiry date.
    guard date > Date() else { return }

    let content = UNMutableNotificationContent()
    content.title = "Medication time"
    content.body = event.medicationName
    // Critical Alerts require an Apple entitlement and are intentionally
    // deferred beyond this MVP. Use the standard local alert sound here.
    content.sound = .default
    content.categoryIdentifier = MediNagNotification.category
    content.userInfo = [MediNagNotification.eventID: event.id]

    let dateComponents = Calendar.current.dateComponents(
      [.calendar, .timeZone, .year, .month, .day, .hour, .minute, .second],
      from: date
    )
    let request = UNNotificationRequest(
      identifier: notificationIdentifier(eventID: event.id),
      content: content,
      trigger: UNCalendarNotificationTrigger(
        dateMatching: dateComponents,
        repeats: false
      )
    )
    try await center.add(request)
  }

  private func notificationIdentifier(eventID: String) -> String {
    "medinag.dose.\(eventID)"
  }
}
