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

enum AlarmRegistrationLedger {
  private static let key = "medinag.registered-alarm-event-identifiers"
  private static let interactionsKey = "medinag.registered-alarm-interactions"
  private static let lock = NSLock()

  static var eventIDs: Set<String> {
    lock.withLock {
      Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }
  }

  static func record(eventID: String) {
    lock.withLock {
      var values = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
      values.insert(eventID)
      UserDefaults.standard.set(Array(values), forKey: key)
    }
  }

  static func record(interaction: NotificationInteraction) throws {
    let data = try JSONEncoder().encode(interaction)
    lock.withLock {
      var values = UserDefaults.standard.dictionary(forKey: interactionsKey) ?? [:]
      values[interaction.eventID] = data
      UserDefaults.standard.set(values, forKey: interactionsKey)
    }
    record(eventID: interaction.eventID)
  }

  static func interaction(for alarmIDs: Set<UUID>) -> NotificationInteraction? {
    lock.withLock {
      let values = UserDefaults.standard.dictionary(forKey: interactionsKey) ?? [:]
      for eventID in values.keys.sorted()
        where alarmIDs.contains(MediNagAlarm.identifier(for: eventID))
      {
        if let data = values[eventID] as? Data,
           let interaction = try? JSONDecoder().decode(NotificationInteraction.self, from: data)
        {
          return interaction
        }
      }
      return nil
    }
  }

  static func remove(eventID: String) {
    lock.withLock {
      var values = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
      values.remove(eventID)
      UserDefaults.standard.set(Array(values), forKey: key)
      var interactions = UserDefaults.standard.dictionary(forKey: interactionsKey) ?? [:]
      interactions.removeValue(forKey: eventID)
      UserDefaults.standard.set(interactions, forKey: interactionsKey)
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
  var realSecondsPerLogicalSecond: Double { get }
  func deliveryDate(for logicalDeadline: Date) -> Date
  func didReceiveNotification(at logicalDeadline: Date)
}

struct SystemNotificationTimeline: NotificationTimeline {
  var realSecondsPerLogicalSecond: Double { 1 }
  var now: Date { Date() }
  func deliveryDate(for logicalDeadline: Date) -> Date { logicalDeadline }
  func didReceiveNotification(at logicalDeadline: Date) {}
}

#if E2E
  final class ScaledNotificationTimeline: NotificationTimeline, @unchecked Sendable {
    var realSecondsPerLogicalSecond: Double { scale }
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

enum NotificationInteractionKind: Codable, Sendable {
  case opened
  case response(DoseResponse)
}

struct NotificationInteraction: Codable, Sendable {
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
  private let deviceQueue = DeviceReminderNotifications()
  private var registeredEvents: [String: MedicationEvent] = [:]
  private var snoozeInterval: TimeInterval = DoseCoordinator.defaultSnoozeInterval

  init(center: UNUserNotificationCenter = .current(),
       timeline: any NotificationTimeline = SystemNotificationTimeline()) {
    self.center = center
    self.timeline = timeline
  }

  static func registerCategories(center: UNUserNotificationCenter = .current()) {
    MediNagNotification.register(center: center)
  }

  func requestAuthorization() async throws -> Bool {
    try await center.requestAuthorization(options: [.alert, .badge, .sound])
  }

  func authorizationStatus() async -> UNAuthorizationStatus {
    await center.notificationSettings().authorizationStatus
  }

  func schedule(event: MedicationEvent) async throws {
    registeredEvents[event.id] = event
    _ = try await reconcile(events: Array(registeredEvents.values),
                            snoozeInterval: snoozeInterval, maximumReminderCount: Int.max)
  }

  func scheduleRepeat(for event: MedicationEvent, at date: Date) async throws {
    registeredEvents[event.id] = event
    if let snoozed = event.lastSnoozedAt { snoozeInterval = date.timeIntervalSince(snoozed) }
    _ = try await reconcile(events: Array(registeredEvents.values),
                            snoozeInterval: snoozeInterval, maximumReminderCount: Int.max)
  }

  func cancel(eventID: String) async {
    registeredEvents.removeValue(forKey: eventID)
    await deviceQueue.cancel(eventID: eventID)
    try? await cancelLegacyAlarm(eventID: eventID)
    NotificationDeliveryLedger.remove(eventID: eventID)
  }

  private func cancelLegacyAlarm(eventID: String) async throws {
    if #available(iOS 26.0, *) {
      // Migration from installed builds: never leave an old Stop-only alarm
      // alongside the new actionable notification sequence.
      let id = MediNagAlarm.identifier(for: eventID)
      if try AlarmManager.shared.alarms.contains(where: { $0.id == id }) {
        try AlarmManager.shared.cancel(id: id)
      }
    }
    AlarmRegistrationLedger.remove(eventID: eventID)
  }

  func reconcile(events: [MedicationEvent], snoozeInterval: TimeInterval,
                 maximumReminderCount: Int) async throws -> NotificationReconciliation {
    registeredEvents = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })
    self.snoozeInterval = snoozeInterval
    for id in AlarmRegistrationLedger.eventIDs {
      try await cancelLegacyAlarm(eventID: id)
    }
    let now = timeline.now
    let ledgerKey = "medinag.actionable.registered-versions"
    let known = UserDefaults.standard.dictionary(forKey: ledgerKey) as? [String: Int] ?? [:]
    let missed = events.filter { event in
      let anchor = event.status == .snoozed
        ? (event.lastSnoozedAt ?? event.scheduledTime).addingTimeInterval(snoozeInterval)
        : event.scheduledTime
      return DoseWindow.isActive(event, among: events, at: now)
        && anchor <= now && known[event.id] != event.snoozeCount
    }.map(\.id)
    let result = try await deviceQueue.reconcile(events: events, snoozeInterval: snoozeInterval,
      logicalNow: now, realNow: timeline.deliveryDate(for: now),
      clockScale: timeline.realSecondsPerLogicalSecond)
    let registered = events.filter { result.registeredEventIDs.contains($0.id) || known[$0.id] == $0.snoozeCount }
    UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: registered.map { ($0.id, $0.snoozeCount) }), forKey: ledgerKey)
    return NotificationReconciliation(expectedPendingCount: result.count,
      actualPendingCount: result.count, scheduledThrough: result.coveredThrough,
      nextReminder: result.nextReminder, missedEventIDs: missed)
  }

  // Kept as a no-op bridge for old activation routing. New delivery is owned
  // by UserNotifications and its real delegate callbacks, not AlarmKit.
  func alertingAlarmIDs() -> Set<UUID> { [] }
  func claimAlarmInteraction(events: [MedicationEvent], candidateAlarmIDs: Set<UUID>) -> NotificationInteraction? { nil }
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
