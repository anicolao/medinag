import Foundation
import MediNagCore
@preconcurrency import UserNotifications

enum MediNagNotification {
  static let category = "MEDINAG_NAG_CATEGORY"
  static let yesIWill = "ACTION_YES_I_WILL"
  static let yesIDid = "ACTION_YES_I_DID"
  static let eventID = "medinagEventID"
  static let medicationName = "medinagMedicationName"
  static let reminderTime = "medinagReminderTime"
  static let reminderNumber = "medinagReminderNumber"
  static let timeZone = "medinagTimeZone"
  static let command = "medinagCompanionCommand"

  static func register(center: UNUserNotificationCenter = .current()) {
    // Foreground actions deliberately launch the device's app to perform the
    // authenticated response and show failures, not pretend a tap was saved.
    center.setNotificationCategories([UNNotificationCategory(identifier: category,
      actions: [
        UNNotificationAction(identifier: yesIDid, title: "Yes, I did", options: [.foreground]),
        UNNotificationAction(identifier: yesIWill, title: "Yes, I will", options: [.foreground]),
      ], intentIdentifiers: [], options: [.customDismissAction])])
  }
}

actor DeviceReminderNotifications {
  private let center = UNUserNotificationCenter.current()
  private var revision = 0

  struct Result: Sendable {
    let count: Int
    let coveredThrough: Date?
    let nextReminder: Date?
    let registeredEventIDs: Set<String>
  }

  func reconcile(events: [MedicationEvent], snoozeInterval: TimeInterval,
                 logicalNow: Date, realNow: Date = Date(), clockScale: Double = 1,
                 snapshot: CompanionSnapshot? = nil) async throws -> Result {
    revision += 1
    let version = revision
    let plan = ReminderPlan(events: events, now: logicalNow, snoozeInterval: snoozeInterval)
    let desired = Set(plan.occurrences.map(\.identifier))
    let pending = await center.pendingNotificationRequests()
    guard revision == version else { throw CancellationError() }
    center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter {
      $0.hasPrefix("medinag.dose.") && !desired.contains($0)
    })
    let delivered = await center.deliveredNotifications()
    guard revision == version else { throw CancellationError() }
    // Clear obsolete response versions, but leave a dismissed/ignored current
    // dose untouched. Dismissal is never a completion or a snooze.
    center.removeDeliveredNotifications(withIdentifiers: delivered.filter { notification in
      let info = notification.request.content.userInfo
      guard let id = info[MediNagNotification.eventID] as? String else { return false }
      guard let event = events.first(where: { $0.id == id }), event.status != .completed else { return true }
      return info[MediNagNotification.reminderNumber] as? Int != event.snoozeCount + 1
    }.map { $0.request.identifier })
    for item in plan.occurrences {
      guard revision == version else { throw CancellationError() }
      if pending.contains(where: {
        $0.identifier == item.identifier && $0.content.body.contains(item.event.medicationName)
          && $0.content.userInfo[MediNagNotification.timeZone] as? String == item.event.timeZone
      }) { continue }
      let content = UNMutableNotificationContent()
      content.title = "Medication reminder"
      var format = Date.FormatStyle(date: .omitted, time: .shortened)
      format.timeZone = TimeZone(identifier: item.event.timeZone) ?? .current
      content.body = "\(item.event.medicationName) · \(item.event.scheduledTime.formatted(format))"
      content.categoryIdentifier = MediNagNotification.category
      content.interruptionLevel = .timeSensitive
      #if os(watchOS)
        content.sound = .default
      #else
        content.sound = UNNotificationSound(named: UNNotificationSoundName("MediNagAlarm.caf"))
      #endif
      content.userInfo = [
        MediNagNotification.eventID: item.event.id,
        MediNagNotification.medicationName: item.event.medicationName,
        MediNagNotification.reminderTime: item.date.timeIntervalSince1970,
        MediNagNotification.reminderNumber: item.event.snoozeCount + 1,
        MediNagNotification.timeZone: item.event.timeZone,
      ]
      if let snapshot {
        content.userInfo[MediNagNotification.command] = try JSONEncoder().encode(
          CompanionCommand(snapshot: snapshot, event: item.event))
      }
      let date = realNow.addingTimeInterval(item.date.timeIntervalSince(logicalNow) * clockScale)
      let components = Calendar.current.dateComponents(
        [.calendar, .timeZone, .year, .month, .day, .hour, .minute, .second], from: date)
      try await center.add(UNNotificationRequest(identifier: item.identifier, content: content,
        trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)))
    }
    let confirmed = await center.pendingNotificationRequests()
    guard revision == version else { throw CancellationError() }
    let count = confirmed.filter { desired.contains($0.identifier) }.count
    guard count == desired.count else {
      throw NSError(domain: "MediNag.NotificationQueue", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Only \(count) of \(desired.count) medication alerts were registered."])
    }
    return Result(count: count, coveredThrough: plan.coveredThrough,
                  nextReminder: plan.occurrences.first?.date,
                  registeredEventIDs: Set(plan.occurrences.map { $0.event.id }))
  }

  func cancel(eventID: String) async {
    revision += 1
    let prefix = "medinag.dose.\(eventID)."
    let pending = await center.pendingNotificationRequests()
    center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(prefix) })
    let delivered = await center.deliveredNotifications()
    center.removeDeliveredNotifications(withIdentifiers: delivered.map { $0.request.identifier }.filter { $0.hasPrefix(prefix) })
  }
}
