import Foundation
import MediNagCore
@preconcurrency import UserNotifications

#if E2E
  enum E2ERuntime {
    private static let timeZoneKey = "medinag.e2e.time-zone"

    static var googleIDToken: String? {
      guard
        let encoded = ProcessInfo.processInfo.arguments.e2eLaunchValue(
          after: "-e2e-google-id-token-base64"
        ),
        let data = Data(base64Encoded: encoded),
        let token = String(data: data, encoding: .utf8),
        !token.isEmpty
      else {
        return nil
      }
      return token
    }

    static var reminderTimeZone: TimeZone {
      let defaults = UserDefaults.standard
      if
        let identifier = ProcessInfo.processInfo.arguments.e2eLaunchValue(
          after: "-e2e-time-zone"
        ),
        let timeZone = TimeZone(identifier: identifier)
      {
        defaults.set(identifier, forKey: timeZoneKey)
        return timeZone
      }
      if
        let identifier = defaults.string(forKey: timeZoneKey),
        let timeZone = TimeZone(identifier: identifier)
      {
        return timeZone
      }
      return .current
    }

    static func notificationTimeline() -> any NotificationTimeline {
      guard
        let value = ProcessInfo.processInfo.arguments.e2eLaunchValue(
          after: "-e2e-logical-now"
        ),
        let logicalNow = ISO8601DateFormatter().date(from: value),
        let scaleValue = ProcessInfo.processInfo.arguments.e2eLaunchValue(
          after: "-e2e-time-scale"
        ),
        let scale = Double(scaleValue),
        scale > 0,
        scale <= 1
      else {
        return SystemNotificationTimeline()
      }
      return ScaledNotificationTimeline(logicalNow: logicalNow, scale: scale)
    }
  }
#endif

private extension Array where Element == String {
  func e2eLaunchValue(after argument: String) -> String? {
    guard let index = firstIndex(of: argument) else { return nil }
    let valueIndex = self.index(after: index)
    guard indices.contains(valueIndex) else { return nil }
    return self[valueIndex]
  }
}

enum MediNagNotification {
  static let category = "MEDINAG_NAG_CATEGORY"
  static let yesIWill = "ACTION_YES_I_WILL"
  static let yesIDid = "ACTION_YES_I_DID"
  static let eventID = "medinagEventID"
  static let medicationName = "medinagMedicationName"
  static let reminderTime = "medinagReminderTime"
  static let reminderNumber = "medinagReminderNumber"
}

enum MediNagDateFormatting {
  static func wallTime(_ value: String) -> String {
    let parts = value.split(separator: ":").compactMap { Int($0) }
    guard parts.count == 2 else { return value }
    let hour = parts[0]
    return "\(hour % 12 == 0 ? 12 : hour % 12):\(String(format: "%02d", parts[1])) \(hour >= 12 ? "PM" : "AM")"
  }

  static func reminderTime(_ date: Date, timeZoneIdentifier: String? = nil) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .none
    formatter.timeStyle = .short
    if let timeZoneIdentifier, let timeZone = TimeZone(identifier: timeZoneIdentifier) {
      formatter.timeZone = timeZone
    }
    return formatter.string(from: date)
  }
}

protocol NotificationTimeline: Clock {
  func deliveryDate(for logicalDeadline: Date) -> Date
}

struct SystemNotificationTimeline: NotificationTimeline {
  var now: Date { Date() }
  func deliveryDate(for logicalDeadline: Date) -> Date { logicalDeadline }
}

#if E2E
  final class ScaledNotificationTimeline: NotificationTimeline, @unchecked Sendable {
    private let logicalAnchor: Date
    private let realAnchor: Date
    private let scale: Double

    init(logicalNow: Date, scale: Double, realNow: Date = Date()) {
      logicalAnchor = logicalNow
      realAnchor = realNow
      self.scale = scale
    }

    var now: Date {
      logicalAnchor.addingTimeInterval(Date().timeIntervalSince(realAnchor) / scale)
    }

    func deliveryDate(for logicalDeadline: Date) -> Date {
      realAnchor.addingTimeInterval(logicalDeadline.timeIntervalSince(logicalAnchor) * scale)
    }
  }
#endif

struct NotificationReconciliation: Equatable, Sendable {
  let expectedPendingCount: Int
  let actualPendingCount: Int
  let scheduledThrough: Date?
  let nextReminder: Date?
  let missedEventIDs: [String]
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
  private let timeline: any NotificationTimeline

  init(
    center: UNUserNotificationCenter = .current(),
    timeline: any NotificationTimeline = SystemNotificationTimeline()
  ) {
    self.center = center
    self.timeline = timeline
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
    let prefix = notificationIdentifierPrefix(eventID: eventID)
    let pendingIdentifiers = await center.pendingNotificationRequests()
      .map(\.identifier)
      .filter { $0.hasPrefix(prefix) }
    let deliveredIdentifiers = await center.deliveredNotifications()
      .map { $0.request.identifier }
      .filter { $0.hasPrefix(prefix) }
    center.removePendingNotificationRequests(withIdentifiers: pendingIdentifiers)
    center.removeDeliveredNotifications(withIdentifiers: deliveredIdentifiers)
  }

  func reconcile(
    events: [MedicationEvent],
    snoozeInterval: TimeInterval,
    maximumReminderCount: Int
  ) async throws -> NotificationReconciliation {
    struct Desired {
      let event: MedicationEvent
      let logicalDate: Date
      let reminderNumber: Int
    }
    let desired = events.compactMap { event -> Desired? in
      guard event.status != .completed else { return nil }
      if event.status == .snoozed {
        guard event.snoozeCount < maximumReminderCount else { return nil }
        return Desired(
          event: event,
          logicalDate: (event.lastSnoozedAt ?? event.scheduledTime)
            .addingTimeInterval(snoozeInterval),
          reminderNumber: event.snoozeCount + 1
        )
      }
      return Desired(event: event, logicalDate: event.scheduledTime, reminderNumber: 1)
    }
    let future = desired.filter { $0.logicalDate > timeline.now }
    let missed = desired.filter { $0.logicalDate <= timeline.now }.map(\.event.id)
    let expectedIdentifiers = Set(future.map {
      Self.notificationIdentifier(
        eventID: $0.event.id,
        reminderNumber: $0.reminderNumber
      )
    })
    let current = await center.pendingNotificationRequests()
    let obsolete = current.map(\.identifier).filter {
      $0.hasPrefix("medinag.dose.") && !expectedIdentifiers.contains($0)
    }
    center.removePendingNotificationRequests(withIdentifiers: obsolete)

    for item in future {
      let identifier = Self.notificationIdentifier(
        eventID: item.event.id,
        reminderNumber: item.reminderNumber
      )
      let deliveryDate = timeline.deliveryDate(for: item.logicalDate)
      let existing = current.first { $0.identifier == identifier }
      let existingDate = (existing?.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
      let unchanged = existingDate.map {
        abs($0.timeIntervalSince(deliveryDate)) < 0.5
          && existing?.content.userInfo[MediNagNotification.reminderTime] as? TimeInterval
            == item.logicalDate.timeIntervalSince1970
      } ?? false
      if !unchanged {
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        try await addNotification(
          for: item.event,
          at: item.logicalDate,
          reminderNumber: item.reminderNumber
        )
      }
    }

    let confirmed = await center.pendingNotificationRequests().filter {
      expectedIdentifiers.contains($0.identifier)
    }
    guard confirmed.count == expectedIdentifiers.count else {
      throw NotificationSchedulingError.pendingRequestMismatch(
        expected: expectedIdentifiers.count,
        actual: confirmed.count
      )
    }
    return NotificationReconciliation(
      expectedPendingCount: expectedIdentifiers.count,
      actualPendingCount: confirmed.count,
      scheduledThrough: future.map(\.logicalDate).max(),
      nextReminder: future.map(\.logicalDate).min(),
      missedEventIDs: missed
    )
  }

  private func addNotification(
    for event: MedicationEvent,
    at date: Date,
    reminderNumber: Int
  ) async throws {
    // Never turn a missed medication time into an immediate, misleading first
    // reminder. Events must be scheduled ahead of time and fire at their
    // absolute medication or snooze-expiry date.
    guard date > timeline.now else { return }
    let deliveryDate = timeline.deliveryDate(for: date)
    guard deliveryDate > Date() else { return }

    let content = UNMutableNotificationContent()
    content.title = reminderNumber == 1 ? "Medication reminder" : "Medication reminder 2"
    content.body = "\(MediNagDateFormatting.reminderTime(date, timeZoneIdentifier: event.timeZone)) • \(event.medicationName)"
    // Critical Alerts require an Apple entitlement and are intentionally
    // deferred beyond this MVP. Use the standard local alert sound here.
    content.sound = .default
    content.interruptionLevel = .timeSensitive
    content.categoryIdentifier = MediNagNotification.category
    content.userInfo = [
      MediNagNotification.eventID: event.id,
      MediNagNotification.medicationName: event.medicationName,
      MediNagNotification.reminderTime: date.timeIntervalSince1970,
      MediNagNotification.reminderNumber: reminderNumber,
    ]

    let dateComponents = Calendar.current.dateComponents(
      [.calendar, .timeZone, .year, .month, .day, .hour, .minute, .second],
      from: deliveryDate
    )
    let request = UNNotificationRequest(
      identifier: notificationIdentifier(
        eventID: event.id,
        reminderNumber: reminderNumber
      ),
      content: content,
      trigger: UNCalendarNotificationTrigger(
        dateMatching: dateComponents,
        repeats: false
      )
    )
    try await center.add(request)
  }

  private static func notificationIdentifier(
    eventID: String,
    reminderNumber: Int
  ) -> String {
    "\(notificationIdentifierPrefix(eventID: eventID)).\(reminderNumber)"
  }

  private static func notificationIdentifierPrefix(eventID: String) -> String {
    "medinag.dose.\(eventID)"
  }

  private func notificationIdentifier(
    eventID: String,
    reminderNumber: Int
  ) -> String {
    Self.notificationIdentifier(eventID: eventID, reminderNumber: reminderNumber)
  }

  private func notificationIdentifierPrefix(eventID: String) -> String {
    Self.notificationIdentifierPrefix(eventID: eventID)
  }
}

enum NotificationSchedulingError: LocalizedError {
  case pendingRequestMismatch(expected: Int, actual: Int)

  var errorDescription: String? {
    switch self {
    case .pendingRequestMismatch(let expected, let actual):
      "iOS retained \(actual) of \(expected) expected medication reminders."
    }
  }
}
