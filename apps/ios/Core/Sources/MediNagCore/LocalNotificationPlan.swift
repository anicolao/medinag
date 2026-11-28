import Foundation

/// Pure planning, shared by the ordinary trial and the future entitled build.
/// Example dates belong in unit tests; real E2E occurrences enter via the dashboard.
public enum LocalNotificationPlan {
  public static let capacity = 60
  public static let window: TimeInterval = 1800
  public struct Slot: Sendable, Equatable {
    public let eventID: String
    public let deadline: Date
  }
  public struct Plan: Sendable {
    public let slots: [Slot]
    public let complete: Bool
  }
  public static func make(events: [MedicationEvent], at now: Date, repeatInterval: TimeInterval,
    budget: Int = capacity) -> Plan {
    let ordered = events.sorted { $0.scheduledTime < $1.scheduledTime }
    let latest = ordered.last { $0.scheduledTime <= now }
    // A completed newest occurrence must never uncover an older pending one.
    let selectedEvents = ordered.filter { $0.status != .completed && ($0.scheduledTime > now || $0.id == latest?.id) }
    var blocks: [[Slot]] = []
    for event in selectedEvents {
      let step = max(60, event.repeatIntervalSeconds ?? repeatInterval)
      let origin = AlertTiming.reminder(for: event, snoozeInterval: event.snoozeIntervalSeconds ?? 600)
      let successor = ordered.first { $0.scheduledTime > event.scheduledTime }?.scheduledTime ?? .distantFuture
      // On an active overdue dose a refresh extends coverage from now. Future
      // doses retain their original first 30 minutes; no app wake is assumed.
      let end = max(origin, now).addingTimeInterval(window)
      var date = origin >= now ? origin : AlarmKitPolicy.gridDeadline(origin: origin, now: now, interval: step)
      var slots: [Slot] = []
      while date <= end && date < successor {
        slots.append(.init(eventID: event.id, deadline: date))
        date = date.addingTimeInterval(step)
      }
      blocks.append(slots)
    }
    let limit = max(0, min(capacity, budget))
    let pair = Array(blocks.prefix(2))
    let complete = pair.reduce(0) { $0 + $1.count } <= limit
    var selected: [Slot] = []
    // Unsafe settings must still reserve both initial alerts, not spend every
    // slot on the first window. The administrator gets an explicit failure.
    if complete {
      selected = pair.flatMap { $0 }
      for block in blocks.dropFirst(2) {
        guard selected.count + block.count <= limit else { break }
        selected.append(contentsOf: block)
      }
    } else {
      for index in 0..<(pair.map(\.count).max() ?? 0) {
        for block in pair where index < block.count && selected.count < limit { selected.append(block[index]) }
      }
    }
    return Plan(slots: selected.sorted { $0.deadline < $1.deadline }, complete: complete)
  }
}
