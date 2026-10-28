import Foundation

/// A bounded, OS-owned queue. Dismissal never changes a dose or this plan.
/// Reserve the first alert for upcoming doses before spending spare slots on
/// unanswered follow-ups. The coverage deadline is the earliest omitted alert,
/// NOT the last (possibly much later) initial dose in the queue.
public struct ReminderPlan: Sendable {
  public static let nagInterval: TimeInterval = 3 * 60
  public static let capacity = 60 // Leave headroom below the system queue limit.

  public struct Occurrence: Sendable {
    public let event: MedicationEvent
    public let date: Date
    public let attempt: Int
    public var identifier: String {
      "medinag.dose.\(event.id).v\(event.snoozeCount).\(Int(date.timeIntervalSince1970)).\(attempt)"
    }
  }

  public let occurrences: [Occurrence]
  public let coveredThrough: Date?

  public init(events: [MedicationEvent], now: Date, snoozeInterval: TimeInterval,
              capacity: Int = Self.capacity) {
    let limit = max(0, capacity)
    let active = events.filter { $0.status != .completed }
    func anchor(_ event: MedicationEvent) -> Date {
      event.status == .snoozed
        ? (event.lastSnoozedAt ?? event.scheduledTime).addingTimeInterval(snoozeInterval)
        : event.scheduledTime
    }
    func ordered(_ lhs: Occurrence, _ rhs: Occurrence) -> Bool {
      if lhs.date == rhs.date { return lhs.identifier < rhs.identifier }
      return lhs.date < rhs.date
    }
    var initial: [Occurrence] = []
    for event in active where anchor(event) > now {
      initial.append(Occurrence(event: event, date: anchor(event), attempt: 0))
    }
    initial.sort(by: ordered)
    var selected = Array(initial.prefix(limit))
    initial = Array(initial.dropFirst(limit))
    var next: [Occurrence] = active.map { event in
      let start = anchor(event)
      let attempt = max(1, Int(floor(now.timeIntervalSince(start) / Self.nagInterval)) + 1)
      return Occurrence(event: event, date: start.addingTimeInterval(Double(attempt) * Self.nagInterval), attempt: attempt)
    }
    while selected.count < limit && !next.isEmpty {
      next.sort(by: ordered)
      let item = next.removeFirst()
      selected.append(item)
      next.append(Occurrence(event: item.event, date: item.date.addingTimeInterval(Self.nagInterval), attempt: item.attempt + 1))
    }
    occurrences = selected.sorted(by: ordered)
    coveredThrough = (initial + next).map(\.date).min().map { $0.addingTimeInterval(-1) }
  }
}
