import Foundation
import MediNagCore
@preconcurrency import UserNotifications

#if E2E
  enum E2ERuntime {
    private static let notificationAccelerationKey =
      "medinag.e2e.notification-acceleration-enabled"

    static var notificationAccelerationEnabled: Bool {
      let defaults = UserDefaults.standard
      if ProcessInfo.processInfo.arguments.contains(
        "-e2e-deliver-notification-on-background"
      ) {
        defaults.set(true, forKey: notificationAccelerationKey)
        return true
      }
      return defaults.bool(forKey: notificationAccelerationKey)
    }
  }
#endif

enum MediNagNotification {
  static let category = "MEDINAG_NAG_CATEGORY"
  static let yesIWill = "ACTION_YES_I_WILL"
  static let yesIDid = "ACTION_YES_I_DID"
  static let eventID = "medinagEventID"
  static let medicationName = "medinagMedicationName"
  static let reminderTime = "medinagReminderTime"
  static let reminderNumber = "medinagReminderNumber"
}

enum NotificationInteractionKind: Sendable {
  case opened
  case response(DoseResponse)
}

struct NotificationInteraction: Sendable {
  let kind: NotificationInteractionKind
  let eventID: String
  let medicationName: String
  let reminderTime: Date
  let reminderNumber: Int
}

@MainActor
final class NotificationResponseRouter {
  static let shared = NotificationResponseRouter()

  var handler: ((NotificationInteraction) -> Void)? {
    didSet { deliverPendingInteractions() }
  }

  private var pendingInteractions: [NotificationInteraction] = []

  private init() {}

  func route(
    actionIdentifier: String,
    eventID: String,
    medicationName: String,
    reminderTime: Date,
    reminderNumber: Int
  ) {
    let kind: NotificationInteractionKind
    switch actionIdentifier {
    case UNNotificationDefaultActionIdentifier:
      kind = .opened
    case MediNagNotification.yesIWill:
      kind = .response(.yesIWill)
    case MediNagNotification.yesIDid:
      kind = .response(.yesIDid)
    default:
      return
    }
    let interaction = NotificationInteraction(
      kind: kind,
      eventID: eventID,
      medicationName: medicationName,
      reminderTime: reminderTime,
      reminderNumber: reminderNumber
    )
    guard let handler else {
      pendingInteractions.append(interaction)
      return
    }
    handler(interaction)
  }

  private func deliverPendingInteractions() {
    guard let handler, !pendingInteractions.isEmpty else { return }
    let interactions = pendingInteractions
    pendingInteractions.removeAll()
    for interaction in interactions {
      handler(interaction)
    }
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
    let date = event.status == .snoozed
      ? (event.lastSnoozedAt ?? event.scheduledTime).addingTimeInterval(
        DoseCoordinator.defaultSnoozeInterval
      )
      : event.scheduledTime
    try await addNotification(
      for: event,
      at: date,
      reminderNumber: event.snoozeCount + 1
    )
  }

  func scheduleRepeat(for event: MedicationEvent, at date: Date) async throws {
    try await addNotification(
      for: event,
      at: date,
      reminderNumber: event.snoozeCount + 1
    )
  }

  func cancel(eventID: String) async {
    #if E2E
      E2ENotificationDeliveryStore.shared.cancel(eventID: eventID)
    #endif
    center.removePendingNotificationRequests(
      withIdentifiers: [notificationIdentifier(eventID: eventID)]
    )
    center.removeDeliveredNotifications(
      withIdentifiers: [notificationIdentifier(eventID: eventID)]
    )
  }

  private func addNotification(
    for event: MedicationEvent,
    at date: Date,
    reminderNumber: Int
  ) async throws {
    #if E2E
      if E2ERuntime.notificationAccelerationEnabled {
        E2ENotificationDeliveryStore.shared.arm(
          event: event,
          date: date,
          reminderNumber: reminderNumber
        )
        return
      }
    #endif
    // Never turn a missed medication time into an immediate, misleading first
    // reminder. Events must be scheduled ahead of time and fire at their
    // absolute medication or snooze-expiry date.
    guard date > Date() else { return }

    let content = UNMutableNotificationContent()
    content.title = reminderNumber == 1 ? "Medication reminder" : "Medication reminder 2"
    content.body = "\(date.formatted(date: .omitted, time: .shortened)) • \(event.medicationName)"
    // Critical Alerts require an Apple entitlement and are intentionally
    // deferred beyond this MVP. Use the standard local alert sound here.
    content.sound = .default
    content.categoryIdentifier = MediNagNotification.category
    content.userInfo = [
      MediNagNotification.eventID: event.id,
      MediNagNotification.medicationName: event.medicationName,
      MediNagNotification.reminderTime: date.timeIntervalSince1970,
      MediNagNotification.reminderNumber: reminderNumber,
    ]

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

  #if E2E
    static func deliverAcceleratedNotification() {
      guard
        E2ERuntime.notificationAccelerationEnabled,
        let reminder = E2ENotificationDeliveryStore.shared.take()
      else {
        return
      }

      let content = UNMutableNotificationContent()
      content.title = reminder.reminderNumber == 1
        ? "Medication reminder"
        : "Medication reminder 2"
      content.body = "\(reminder.date.formatted(date: .omitted, time: .shortened)) • \(reminder.event.medicationName)"
      content.sound = .default
      content.categoryIdentifier = MediNagNotification.category
      content.userInfo = [
        MediNagNotification.eventID: reminder.event.id,
        MediNagNotification.medicationName: reminder.event.medicationName,
        MediNagNotification.reminderTime: reminder.date.timeIntervalSince1970,
        MediNagNotification.reminderNumber: reminder.reminderNumber,
      ]
      UNUserNotificationCenter.current().add(
        UNNotificationRequest(
          identifier: "medinag.dose.\(reminder.event.id)",
          content: content,
          trigger: nil
        ),
        withCompletionHandler: nil
      )
    }
  #endif

  private func notificationIdentifier(eventID: String) -> String {
    "medinag.dose.\(eventID)"
  }
}

#if E2E
  private struct E2EArmedNotification: Sendable {
    let event: MedicationEvent
    let date: Date
    let reminderNumber: Int
  }

  private final class E2ENotificationDeliveryStore: @unchecked Sendable {
    static let shared = E2ENotificationDeliveryStore()

    private let lock = NSLock()
    private var reminder: E2EArmedNotification?

    func arm(event: MedicationEvent, date: Date, reminderNumber: Int) {
      lock.withLock {
        reminder = E2EArmedNotification(
          event: event,
          date: date,
          reminderNumber: reminderNumber
        )
      }
    }

    func take() -> E2EArmedNotification? {
      lock.withLock {
        defer { reminder = nil }
        return reminder
      }
    }

    func cancel(eventID: String) {
      lock.withLock {
        if reminder?.event.id == eventID {
          reminder = nil
        }
      }
    }
  }
#endif
