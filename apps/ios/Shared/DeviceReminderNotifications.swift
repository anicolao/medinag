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
  static let eventData = "medinagEventData"

  static func register(center: UNUserNotificationCenter = .current()) {
    // A choice completes in the background. Never force the patient to open
    // the app or wait on Firebase after responding in the system notification.
    center.setNotificationCategories([UNNotificationCategory(identifier: category,
      actions: [
        UNNotificationAction(identifier: yesIDid, title: "Yes, I did", options: []),
        UNNotificationAction(identifier: yesIWill, title: "Yes, I will", options: []),
      ], intentIdentifiers: [], options: [.customDismissAction])])
  }
}

actor DeviceReminderNotifications {
  static let shared = DeviceReminderNotifications()
  private let center = UNUserNotificationCenter.current()
  private var revision = 0
  private let responseProgress = NotificationResponseProgress()

  struct Result: Sendable {
    let count: Int
    let coveredThrough: Date?
    let nextReminder: Date?
    let registeredEventIDs: Set<String>
  }

  func reconcile(events incomingEvents: [MedicationEvent], snoozeInterval: TimeInterval,
                 repeatInterval: TimeInterval = ReminderPlan.nagInterval,
                 logicalNow: Date, realNow: Date = Date(), clockScale: Double = 1,
                 snapshot: CompanionSnapshot? = nil) async throws -> Result {
    revision += 1
    let version = revision
    // Final serialized boundary: even an older refresh that starts after a tap
    // cannot undo cancellation. Persist before touching OS requests.
    let events = try responseProgress.protecting(incomingEvents)
    let pending = await center.pendingNotificationRequests()
    guard revision == version else { throw CancellationError() }
    let projected = ReminderPlan(events: events, now: logicalNow, snoozeInterval: snoozeInterval,
      repeatInterval: repeatInterval)
    let projectedIDs = Set(projected.occurrences.map(\.identifier))
    let inFlight = pending.filter { request in
      guard request.identifier.hasPrefix("medinag.dose."), !projectedIDs.contains(request.identifier),
        let data = request.content.userInfo[MediNagNotification.eventData] as? Data,
        let queued = try? JSONDecoder().decode(MedicationEvent.self, from: data),
        let deadline = request.content.userInfo[MediNagNotification.reminderTime] as? Double else { return false }
      return ReminderPlan.retainsInFlight(queued, deadline: Date(timeIntervalSince1970: deadline),
        among: events, now: logicalNow, snoozeInterval: snoozeInterval)
    }
    for request in inFlight {
      LocalAlertJournal.record("due_request_retained", requestID: request.identifier)
    }
    let plan = ReminderPlan(events: events, now: logicalNow, snoozeInterval: snoozeInterval,
      repeatInterval: repeatInterval, capacity: max(0, ReminderPlan.capacity - inFlight.count))
    LocalAlertJournal.record("queue_plan", deadline: plan.coveredThrough,
      details: ["logicalNow": String(logicalNow.timeIntervalSince1970),
        "repeatSeconds": String(repeatInterval), "snoozeSeconds": String(snoozeInterval),
        "count": String(plan.occurrences.count), "clockScale": String(clockScale),
        "inFlightRetained": String(inFlight.count),
        "requiredPairRequests": String(plan.requiredPairRequestCount),
        "requiredPairCovered": String(plan.requiredPairCovered),
        "protectedDoseWindows": String(plan.protectedEventIDs.count)])
    let desired = Set(plan.occurrences.map(\.identifier) + inFlight.map(\.identifier))
    // Calendar triggers have second precision. Never round a deadline down
    // into the past, especially when registering a near-due follow-up.
    func deliveryDate(_ occurrence: ReminderPlan.Occurrence) -> Date {
      let raw = realNow.addingTimeInterval(occurrence.date.timeIntervalSince(logicalNow) * clockScale)
      return Date(timeIntervalSince1970: ceil(raw.timeIntervalSince1970))
    }
    let obsolete = pending.map(\.identifier).filter {
      $0.hasPrefix("medinag.dose.") && !desired.contains($0)
    }
    center.removePendingNotificationRequests(withIdentifiers: obsolete)
    for identifier in obsolete {
      LocalAlertJournal.record("local_cancellation_requested", requestID: identifier,
        details: ["reason": "queue_reconciliation"])
    }
    let delivered = await center.deliveredNotifications()
    for item in delivered {
      LocalAlertJournal.record("delivered_item_observed", requestID: item.request.identifier,
        details: ["systemDeliveryDate": String(item.date.timeIntervalSince1970)])
    }
    guard revision == version else { throw CancellationError() }
    // Clear obsolete response versions, but leave a dismissed/ignored current
    // dose untouched. Dismissal is never a completion or a snooze.
    center.removeDeliveredNotifications(withIdentifiers: delivered.filter { notification in
      let info = notification.request.content.userInfo
      guard let id = info[MediNagNotification.eventID] as? String else { return false }
      guard let event = events.first(where: { $0.id == id }),
            DoseWindow.isActive(event, among: events, at: logicalNow) else { return true }
      return info[MediNagNotification.reminderNumber] as? Int != event.snoozeCount + 1
    }.map { $0.request.identifier })
    for item in plan.occurrences {
      guard revision == version else { throw CancellationError() }
      if pending.contains(where: {
        $0.identifier == item.identifier && $0.content.body.isEmpty
          && $0.content.userInfo[MediNagNotification.timeZone] as? String == item.event.timeZone
      }) { continue }
      let content = UNMutableNotificationContent()
      content.title = "Medication reminder"
      content.body = ""
      content.categoryIdentifier = MediNagNotification.category
      content.interruptionLevel = .timeSensitive
      #if os(watchOS)
        content.sound = .default
      #else
        content.sound = UNNotificationSound(named: UNNotificationSoundName("MediNagAlarm.caf"))
      #endif
      content.userInfo = [
        MediNagNotification.eventData: try JSONEncoder().encode(item.event),
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
      let date = deliveryDate(item)
      LocalAlertJournal.record("registration_attempted", eventID: item.event.id,
        requestID: item.identifier, deadline: date,
        details: ["logicalDeadline": String(item.date.timeIntervalSince1970)])
      let components = Calendar.current.dateComponents(
        [.calendar, .timeZone, .year, .month, .day, .hour, .minute, .second], from: date)
      do {
        try await center.add(UNNotificationRequest(identifier: item.identifier, content: content,
          trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)))
        LocalAlertJournal.record("registration_accepted", eventID: item.event.id,
          requestID: item.identifier, deadline: date)
      } catch {
        LocalAlertJournal.record("registration_rejected", eventID: item.event.id,
          requestID: item.identifier, deadline: date, details: ["error": error.localizedDescription])
        throw error
      }
    }
    let confirmed = await center.pendingNotificationRequests()
    guard revision == version else { throw CancellationError() }
    let obsoleteRemaining = confirmed.filter { $0.identifier.hasPrefix("medinag.dose.") && !desired.contains($0.identifier) }
    LocalAlertJournal.record("obsolete_inventory_observed", details: ["actual": String(obsoleteRemaining.count)])
    guard obsoleteRemaining.isEmpty else {
      throw NSError(domain: "MediNag.NotificationQueue", code: 3,
        userInfo: [NSLocalizedDescriptionKey: "The OS still lists \(obsoleteRemaining.count) cancelled medication requests."])
    }
    // Already-due requests can legitimately have left the pending inventory
    // while the async registration calls were in progress. Do not call them
    // pending or claim they were delivered; verify FUTURE requests only.
    let verifiedAt = Date()
    let future = plan.occurrences.filter { deliveryDate($0) > verifiedAt }
    var deadlines = Dictionary(uniqueKeysWithValues: plan.occurrences.map { ($0.identifier, deliveryDate($0)) })
    for request in inFlight {
      // A rounded calendar deadline can still be in the future even though
      // its logical deadline has passed. Verify it too, without inventing a
      // delivery receipt if nextTriggerDate is already nil.
      if let date = request.trigger?.nextTriggerDate() { deadlines[request.identifier] = date }
    }
    let inventory = ReminderInventory(
      deadlines: deadlines,
      pending: Set(confirmed.map(\.identifier)), at: verifiedAt)
    let count = inventory.actual.count
    LocalAlertJournal.record("future_inventory_observed", deadline: plan.coveredThrough,
      details: ["expected": String(inventory.expected.count), "actual": String(count)])
    guard inventory.complete else {
      throw NSError(domain: "MediNag.NotificationQueue", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Only \(count) of \(inventory.expected.count) future medication alerts were registered (\(plan.occurrences.count - future.count) became due during reconciliation)."])
    }
    guard plan.requiredPairCovered else {
      LocalAlertJournal.record("insufficient_two_dose_capacity", deadline: plan.coveredThrough,
        details: ["required": String(plan.requiredPairRequestCount + inFlight.count), "capacity": String(ReminderPlan.capacity)])
      throw NSError(domain: "MediNag.NotificationQueue", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "The current and next dose plus \(inFlight.count) valid in-flight alerts require \(plan.requiredPairRequestCount + inFlight.count) requests, exceeding the \(ReminderPlan.capacity)-request queue. Best-effort alerts are registered; full coverage is NOT established."])
    }
    return Result(count: count, coveredThrough: plan.coveredThrough,
                  nextReminder: future.first?.date,
                  registeredEventIDs: Set(plan.occurrences.map { $0.event.id }
                    + inFlight.compactMap { $0.content.userInfo[MediNagNotification.eventID] as? String }))
  }

  func cancel(eventID: String) async {
    revision += 1
    let prefix = "medinag.dose.\(eventID)."
    let pending = await center.pendingNotificationRequests()
    center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(prefix) })
    let delivered = await center.deliveredNotifications()
    center.removeDeliveredNotifications(withIdentifiers: delivered.map { $0.request.identifier }.filter { $0.hasPrefix(prefix) })
    LocalAlertJournal.record("local_cancellation_requested", eventID: eventID)
  }
}
