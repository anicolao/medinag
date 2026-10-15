import ActivityKit
import AlarmKit
import CryptoKit
import Foundation
import MediNagCore
import SwiftUI
@preconcurrency import UserNotifications

#if E2E
  enum E2ERuntime {
    private static let timeZoneKey = "medinag.e2e.time-zone"
    private static let logicalNowKey = "medinag.e2e.logical-now"
    private static let timeScaleKey = "medinag.e2e.time-scale"

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
      let defaults = UserDefaults.standard
      let arguments = ProcessInfo.processInfo.arguments
      if
        let logicalNowValue = arguments.e2eLaunchValue(after: "-e2e-logical-now"),
        let scaleValue = arguments.e2eLaunchValue(after: "-e2e-time-scale")
      {
        defaults.set(logicalNowValue, forKey: logicalNowKey)
        defaults.set(scaleValue, forKey: timeScaleKey)
      }
      guard
        let logicalNowValue = defaults.string(forKey: logicalNowKey),
        let logicalNow = ISO8601DateFormatter().date(from: logicalNowValue),
        let scaleValue = defaults.string(forKey: timeScaleKey),
        let scale = Double(scaleValue), scale > 0, scale <= 1
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
  static let timeZone = "medinagTimeZone"
}

enum MediNagAlarm {
  static let soundName = "MediNagAlarm.caf"

  static func identifier(for eventID: String) -> UUID {
    let digest = SHA256.hash(data: Data(eventID.utf8))
    let hex = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    let part1 = String(hex.prefix(8))
    let part2 = String(hex.dropFirst(8).prefix(4))
    let part3 = String(hex.dropFirst(12).prefix(4))
    let part4 = String(hex.dropFirst(16).prefix(4))
    let part5 = String(hex.dropFirst(20).prefix(12))
    let value = "\(part1)-\(part2)-\(part3)-\(part4)-\(part5)"
    return UUID(uuidString: value)!
  }

  static var sound: AlertConfiguration.AlertSound {
    #if targetEnvironment(simulator)
      // iOS 26 Simulator's ToneLibrary aborts SpringBoard while preparing any
      // external AlarmKit sound (`-[AVAudioSession reporterID]`). Keep the
      // system alarm and its real action flow testable there; device archives
      // always use the bundled medication alarm below.
      return .default
    #else
      return .named(soundName)
    #endif
  }
}

@available(iOS 26.0, *)
private struct MedicationAlarmMetadata: AlarmMetadata {
  let eventID: String
  let medicationName: String
  let reminderTime: Date
  let reminderNumber: Int
  let timeZoneIdentifier: String
}

enum NotificationDeliveryLedger {
  private static let key = "medinag.notification-delivery-identifiers"
  private static let lock = NSLock()

  static var identifiers: Set<String> {
    lock.withLock {
      Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }
  }

  static func record(identifier: String) {
    guard identifier.hasPrefix("medinag.dose.") else { return }
    lock.withLock {
      var values = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
      values.insert(identifier)
      UserDefaults.standard.set(Array(values), forKey: key)
    }
  }

  static func claim(identifier: String) -> Bool {
    guard identifier.hasPrefix("medinag.dose.") else { return false }
    return lock.withLock {
      var values = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
      guard values.insert(identifier).inserted else { return false }
      UserDefaults.standard.set(Array(values), forKey: key)
      return true
    }
  }

  static func remove(eventID: String) {
    let prefix = "medinag.dose.\(eventID)."
    lock.withLock {
      let values = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        .filter { !$0.hasPrefix(prefix) }
      UserDefaults.standard.set(Array(values), forKey: key)
    }
  }
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
  func didReceiveNotification(at logicalDeadline: Date)
}

struct SystemNotificationTimeline: NotificationTimeline {
  var now: Date { Date() }
  func deliveryDate(for logicalDeadline: Date) -> Date { logicalDeadline }
  func didReceiveNotification(at logicalDeadline: Date) {}
}

#if E2E
  final class ScaledNotificationTimeline: NotificationTimeline, @unchecked Sendable {
    private static let realAnchorKey = "medinag.e2e.real-anchor"
    private let logicalAnchor: Date
    private let scale: Double
    private let lock = NSLock()
    private var realAnchor: Date?

    init(logicalNow: Date, scale: Double) {
      logicalAnchor = logicalNow
      self.scale = scale
      let defaults = UserDefaults.standard
      if defaults.object(forKey: Self.realAnchorKey) != nil {
        realAnchor = Date(
          timeIntervalSince1970: defaults.double(forKey: Self.realAnchorKey)
        )
      }
    }

    var now: Date {
      lock.withLock {
        guard let realAnchor else { return logicalAnchor }
        return logicalAnchor.addingTimeInterval(
          Date().timeIntervalSince(realAnchor) / scale
        )
      }
    }

    func deliveryDate(for logicalDeadline: Date) -> Date {
      lock.withLock {
        let anchor = realAnchor ?? Date()
        realAnchor = anchor
        UserDefaults.standard.set(
          anchor.timeIntervalSince1970,
          forKey: Self.realAnchorKey
        )
        return anchor.addingTimeInterval(
          logicalDeadline.timeIntervalSince(logicalAnchor) * scale
        )
      }
    }

    // Preserve the original affine clock mapping. Moving the anchor when an
    // alarm is opened would make every already-registered future AlarmKit date
    // appear changed, which is unlike the production identity timeline.
    func didReceiveNotification(at logicalDeadline: Date) {}
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
  let timeZoneIdentifier: String

  init(
    kind: NotificationInteractionKind,
    eventID: String,
    medicationName: String,
    reminderTime: Date,
    reminderNumber: Int,
    timeZoneIdentifier: String
  ) {
    self.kind = kind
    self.eventID = eventID
    self.medicationName = medicationName
    self.reminderTime = reminderTime
    self.reminderNumber = reminderNumber
    self.timeZoneIdentifier = timeZoneIdentifier
  }

  init?(
    actionIdentifier: String,
    userInfo: [AnyHashable: Any]
  ) {
    let interactionKind: NotificationInteractionKind
    switch actionIdentifier {
    case UNNotificationDefaultActionIdentifier:
      interactionKind = .opened
    case MediNagNotification.yesIWill:
      interactionKind = .response(.yesIWill)
    case MediNagNotification.yesIDid:
      interactionKind = .response(.yesIDid)
    default:
      return nil
    }
    guard
      let eventID = userInfo[MediNagNotification.eventID] as? String,
      let medicationName = userInfo[MediNagNotification.medicationName] as? String,
      let reminderTimestamp = userInfo[MediNagNotification.reminderTime] as? TimeInterval,
      let reminderNumber = userInfo[MediNagNotification.reminderNumber] as? Int
    else {
      return nil
    }
    self.init(
      kind: interactionKind,
      eventID: eventID,
      medicationName: medicationName,
      reminderTime: Date(timeIntervalSince1970: reminderTimestamp),
      reminderNumber: reminderNumber,
      timeZoneIdentifier: userInfo[MediNagNotification.timeZone] as? String
        ?? TimeZone.autoupdatingCurrent.identifier
    )
  }
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
    reminderNumber: Int,
    timeZoneIdentifier: String
  ) {
    let interaction = NotificationInteraction(
      actionIdentifier: actionIdentifier,
      userInfo: [
        MediNagNotification.eventID: eventID,
        MediNagNotification.medicationName: medicationName,
        MediNagNotification.reminderTime: reminderTime.timeIntervalSince1970,
        MediNagNotification.reminderNumber: reminderNumber,
        MediNagNotification.timeZone: timeZoneIdentifier,
      ]
    )
    guard let interaction else { return }
    route(interaction)
  }

  func route(_ interaction: NotificationInteraction) {
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

actor LocalNotificationScheduler: NotificationScheduling {
  private let center: UNUserNotificationCenter
  private let timeline: any NotificationTimeline
  private var acknowledgedAlarmEventIDs: Set<String> = []
  private var registeredAlarmEventIDs: Set<String> = []

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
    if #available(iOS 26.0, *) {
      return try await AlarmManager.shared.requestAuthorization() == .authorized
    }
    return try await center.requestAuthorization(options: [.alert, .badge, .sound])
  }

  func authorizationStatus() async -> UNAuthorizationStatus {
    if #available(iOS 26.0, *) {
      switch AlarmManager.shared.authorizationState {
      case .authorized: return .authorized
      case .denied: return .denied
      case .notDetermined: return .notDetermined
      @unknown default: return .notDetermined
      }
    }
    return await center.notificationSettings().authorizationStatus
  }

  func schedule(event: MedicationEvent) async throws {
    let date = event.status == .snoozed
      ? (event.lastSnoozedAt ?? event.scheduledTime).addingTimeInterval(
        DoseCoordinator.defaultSnoozeInterval
      )
      : event.scheduledTime
    if #available(iOS 26.0, *) {
      try await scheduleAlarm(
        for: event,
        at: date,
        reminderNumber: event.snoozeCount + 1
      )
    } else {
      try await addNotification(
        for: event,
        at: date,
        reminderNumber: event.snoozeCount + 1
      )
    }
  }

  func scheduleRepeat(for event: MedicationEvent, at date: Date) async throws {
    if #available(iOS 26.0, *) {
      acknowledgedAlarmEventIDs.remove(event.id)
      registeredAlarmEventIDs.remove(event.id)
      try? AlarmManager.shared.cancel(id: MediNagAlarm.identifier(for: event.id))
      try await scheduleAlarm(
        for: event,
        at: date,
        reminderNumber: event.snoozeCount + 1
      )
    } else {
      try await addNotification(
        for: event,
        at: date,
        reminderNumber: event.snoozeCount + 1
      )
    }
  }

  func cancel(eventID: String) async {
    acknowledgedAlarmEventIDs.remove(eventID)
    registeredAlarmEventIDs.remove(eventID)
    if #available(iOS 26.0, *) {
      try? AlarmManager.shared.cancel(id: MediNagAlarm.identifier(for: eventID))
    }
    let prefix = notificationIdentifierPrefix(eventID: eventID)
    let pendingIdentifiers = await center.pendingNotificationRequests()
      .map(\.identifier)
      .filter { $0.hasPrefix(prefix) }
    let deliveredIdentifiers = await center.deliveredNotifications()
      .map { $0.request.identifier }
      .filter { $0.hasPrefix(prefix) }
    center.removePendingNotificationRequests(withIdentifiers: pendingIdentifiers)
    center.removeDeliveredNotifications(withIdentifiers: deliveredIdentifiers)
    NotificationDeliveryLedger.remove(eventID: eventID)
  }

  func reconcile(
    events: [MedicationEvent],
    snoozeInterval: TimeInterval,
    maximumReminderCount: Int
  ) async throws -> NotificationReconciliation {
    if #available(iOS 26.0, *) {
      return try await reconcileAlarms(
        events: events,
        snoozeInterval: snoozeInterval,
        maximumReminderCount: maximumReminderCount
      )
    }
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
    let deliveredIdentifiers = Set(
      await center.deliveredNotifications().map { $0.request.identifier }
    ).union(NotificationDeliveryLedger.identifiers)
    let future = desired.filter { $0.logicalDate > timeline.now }
    let missed = desired.filter {
      let identifier = Self.notificationIdentifier(
        eventID: $0.event.id,
        reminderNumber: $0.reminderNumber
      )
      return $0.logicalDate <= timeline.now
        && !deliveredIdentifiers.contains(identifier)
    }.map(\.event.id)
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
          && existing?.content.userInfo[MediNagNotification.timeZone] as? String
            == item.event.timeZone
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

  func claimAlarmInteraction(
    events: [MedicationEvent],
    includeAlertingAlarm: Bool = false
  ) -> NotificationInteraction? {
    guard #available(iOS 26.0, *) else { return nil }
    guard includeAlertingAlarm else { return nil }
    let current = (try? AlarmManager.shared.alarms) ?? []
    let alertingIDs = Set(current.filter { $0.state == .alerting }.map(\.id))
    guard
      let event = events.first(where: {
        alertingIDs.contains(MediNagAlarm.identifier(for: $0.id))
      })
    else { return nil }
    try? AlarmManager.shared.stop(id: MediNagAlarm.identifier(for: event.id))
    acknowledgedAlarmEventIDs.insert(event.id)
    return NotificationInteraction(
      kind: .opened,
      eventID: event.id,
      medicationName: event.medicationName,
      reminderTime: event.status == .snoozed
        ? event.lastSnoozedAt ?? event.scheduledTime
        : event.scheduledTime,
      reminderNumber: event.snoozeCount + 1,
      timeZoneIdentifier: event.timeZone
    )
  }

  @available(iOS 26.0, *)
  private func reconcileAlarms(
    events: [MedicationEvent],
    snoozeInterval: TimeInterval,
    maximumReminderCount: Int
  ) async throws -> NotificationReconciliation {
    struct Desired {
      let event: MedicationEvent
      let logicalDate: Date
      let reminderNumber: Int
    }
    let current: [Alarm]
    do {
      current = try AlarmManager.shared.alarms
    } catch {
      throw NotificationSchedulingError.alarmInventoryUnavailable(
        error.localizedDescription
      )
    }
    let currentByID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
    let unfinished = events.filter { $0.status != .completed }
    registeredAlarmEventIDs = registeredAlarmEventIDs.filter { eventID in
      unfinished.contains { $0.id == eventID }
    }
    for event in unfinished
      where currentByID[MediNagAlarm.identifier(for: event.id)] != nil
    {
      registeredAlarmEventIDs.insert(event.id)
    }
    acknowledgedAlarmEventIDs = acknowledgedAlarmEventIDs.filter { eventID in
      unfinished.contains { $0.id == eventID && $0.status == .pending }
    }
    let desired = unfinished.compactMap { event -> Desired? in
      // Opening the system alarm stops its alert before the patient has
      // selected a dose response in the app. That acknowledged alarm is no
      // longer a missing registration.
      guard !acknowledgedAlarmEventIDs.contains(event.id) else { return nil }
      let identifier = MediNagAlarm.identifier(for: event.id)
      let existing = currentByID[identifier]
      let systemStillOwnsAlarm: Bool
      switch (existing?.state, existing?.schedule) {
      case (.alerting?, _), (.countdown?, _), (.paused?, _):
        systemStillOwnsAlarm = true
      case (.scheduled?, _):
        // AlarmKit may keep an alarm in `scheduled` briefly after its fixed
        // date while mobiletimerd starts the system alert. Never revoke that
        // OS-owned delivery merely because reconciliation ran in that window.
        systemStillOwnsAlarm = true
      default:
        systemStillOwnsAlarm = false
      }
      if systemStillOwnsAlarm {
        return Desired(
          event: event,
          logicalDate: event.status == .snoozed
            ? (event.lastSnoozedAt ?? event.scheduledTime)
              .addingTimeInterval(snoozeInterval)
            : event.scheduledTime,
          reminderNumber: event.snoozeCount + 1
        )
      }
      if event.status == .snoozed && event.snoozeCount >= maximumReminderCount {
        return nil
      }
      let date = event.status == .snoozed
        ? (event.lastSnoozedAt ?? event.scheduledTime)
          .addingTimeInterval(snoozeInterval)
        : event.scheduledTime
      guard date > timeline.now else { return nil }
      return Desired(
        event: event,
        logicalDate: date,
        reminderNumber: event.snoozeCount + 1
      )
    }
    let desiredIDs = Set(desired.map { MediNagAlarm.identifier(for: $0.event.id) })
    var transitioningIDs = Set(current.compactMap { alarm -> UUID? in
      guard desiredIDs.contains(alarm.id) else { return nil }
      if alarm.state == .alerting { return alarm.id }
      if case .fixed(let date) = alarm.schedule, date <= Date() { return alarm.id }
      return nil
    })
    // A firing AlarmKit alarm can disappear from `alarms` while iOS opens its
    // owning app. A successful schedule call plus a reached delivery date is
    // proof that iOS owned that occurrence, not evidence of a missing alarm.
    for item in desired
      where registeredAlarmEventIDs.contains(item.event.id)
        && timeline.deliveryDate(for: item.logicalDate) <= Date()
    {
      transitioningIDs.insert(MediNagAlarm.identifier(for: item.event.id))
    }
    let expectedPendingIDs = desiredIDs.subtracting(transitioningIDs)
    for alarm in current where !desiredIDs.contains(alarm.id) {
      try? AlarmManager.shared.cancel(id: alarm.id)
    }

    var confirmedIDs: Set<UUID> = []
    for item in desired {
      let identifier = MediNagAlarm.identifier(for: item.event.id)
      if transitioningIDs.contains(identifier) {
        continue
      }
      let deliveryDate = timeline.deliveryDate(for: item.logicalDate)
      let unchanged = currentByID[identifier].map { alarm in
        if alarm.state == .alerting || alarm.state == .countdown || alarm.state == .paused {
          return true
        }
        guard case .fixed(let date) = alarm.schedule else { return false }
        return abs(date.timeIntervalSince(deliveryDate)) < 0.5
      } ?? false
      if !unchanged {
        registeredAlarmEventIDs.remove(item.event.id)
        try? AlarmManager.shared.cancel(id: identifier)
        try await scheduleAlarm(
          for: item.event,
          at: item.logicalDate,
          reminderNumber: item.reminderNumber
        )
      }
      // Either the existing AlarmKit record was validated above or the
      // throwing schedule API just accepted its replacement. Reading the
      // manager again here is eventually consistent while an alarm fires and
      // can transiently omit a successfully registered record.
      confirmedIDs.insert(identifier)
    }

    let missed = unfinished.filter { event in
      let date = event.status == .snoozed
        ? (event.lastSnoozedAt ?? event.scheduledTime)
          .addingTimeInterval(snoozeInterval)
        : event.scheduledTime
      let systemOwnedOccurrence = registeredAlarmEventIDs.contains(event.id)
        || acknowledgedAlarmEventIDs.contains(event.id)
      return date <= timeline.now
        && !systemOwnedOccurrence
        && currentByID[MediNagAlarm.identifier(for: event.id)]?.state != .alerting
    }.map(\.id)
    guard confirmedIDs.count == expectedPendingIDs.count else {
      throw NotificationSchedulingError.pendingRequestMismatch(
        expected: expectedPendingIDs.count,
        actual: confirmedIDs.count
      )
    }
    return NotificationReconciliation(
      expectedPendingCount: expectedPendingIDs.count,
      actualPendingCount: confirmedIDs.count,
      scheduledThrough: desired.map(\.logicalDate).max(),
      nextReminder: desired.map(\.logicalDate).min(),
      missedEventIDs: missed
    )
  }

  @available(iOS 26.0, *)
  private func scheduleAlarm(
    for event: MedicationEvent,
    at logicalDate: Date,
    reminderNumber: Int
  ) async throws {
    guard logicalDate > timeline.now else { return }
    let deliveryDate = timeline.deliveryDate(for: logicalDate)
    guard deliveryDate > Date() else {
      throw NotificationSchedulingError.deliveryDeadlinePassed
    }
    let reminderLabel = reminderNumber == 1
      ? "Medication reminder"
      : "Medication reminder \(reminderNumber)"
    let title = LocalizedStringResource(
      stringLiteral: "\(reminderLabel): \(event.medicationName)"
    )
    let alert: AlarmPresentation.Alert
    if #available(iOS 26.1, *) {
      alert = AlarmPresentation.Alert(title: title)
    } else {
      alert = AlarmPresentation.Alert(
        title: title,
        stopButton: AlarmButton(
          text: "Stop",
          textColor: .red,
          systemImageName: "stop.fill"
        )
      )
    }
    let attributes = AlarmAttributes(
      presentation: AlarmPresentation(alert: alert),
      metadata: MedicationAlarmMetadata(
        eventID: event.id,
        medicationName: event.medicationName,
        reminderTime: logicalDate,
        reminderNumber: reminderNumber,
        timeZoneIdentifier: event.timeZone
      ),
      tintColor: .red
    )
    let configuration = AlarmManager.AlarmConfiguration.alarm(
      schedule: .fixed(deliveryDate),
      attributes: attributes,
      sound: MediNagAlarm.sound
    )
    do {
      _ = try await AlarmManager.shared.schedule(
        id: MediNagAlarm.identifier(for: event.id),
        configuration: configuration
      )
    } catch {
      throw NotificationSchedulingError.alarmRegistrationFailed(
        eventID: event.id,
        reason: error.localizedDescription
      )
    }
    registeredAlarmEventIDs.insert(event.id)
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
    content.sound = UNNotificationSound(
      named: UNNotificationSoundName(MediNagAlarm.soundName)
    )
    content.interruptionLevel = .timeSensitive
    content.categoryIdentifier = MediNagNotification.category
    content.userInfo = [
      MediNagNotification.eventID: event.id,
      MediNagNotification.medicationName: event.medicationName,
      MediNagNotification.reminderTime: date.timeIntervalSince1970,
      MediNagNotification.reminderNumber: reminderNumber,
      MediNagNotification.timeZone: event.timeZone,
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
  case deliveryDeadlinePassed
  case alarmInventoryUnavailable(String)
  case alarmRegistrationFailed(eventID: String, reason: String)

  var errorDescription: String? {
    switch self {
    case .pendingRequestMismatch(let expected, let actual):
      "iOS retained \(actual) of \(expected) expected medication reminders."
    case .deliveryDeadlinePassed:
      "The reminder deadline passed before iOS accepted the alarm."
    case .alarmInventoryUnavailable(let reason):
      "iOS could not read its registered alarms: \(reason)"
    case .alarmRegistrationFailed(let eventID, let reason):
      "iOS rejected alarm \(eventID): \(reason)"
    }
  }
}
