import Foundation

/// A bounded, OS-owned queue. Dismissal never changes a dose or this plan.
/// Register the earliest alerts first, without letting far-future initial doses
/// crowd out current follow-ups. The coverage deadline is the earliest omitted alert,
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
    let active = events.filter { DoseWindow.isActive($0, among: events, at: now) }
    func anchor(_ event: MedicationEvent) -> Date {
      event.status == .snoozed
        ? (event.lastSnoozedAt ?? event.scheduledTime).addingTimeInterval(snoozeInterval)
        : event.scheduledTime
    }
    func ordered(_ lhs: Occurrence, _ rhs: Occurrence) -> Bool {
      if lhs.date == rhs.date { return lhs.identifier < rhs.identifier }
      return lhs.date < rhs.date
    }
    var selected: [Occurrence] = []
    var next: [Occurrence] = active.compactMap { event in
      let start = anchor(event)
      let attempt = start > now ? 0 : max(1, Int(floor(now.timeIntervalSince(start) / Self.nagInterval)) + 1)
      let date = start.addingTimeInterval(Double(attempt) * Self.nagInterval)
      guard DoseWindow.end(for: event, among: events).map({ date < $0 }) ?? true else { return nil }
      return Occurrence(event: event, date: date, attempt: attempt)
    }
    while selected.count < limit && !next.isEmpty {
      next.sort(by: ordered)
      let item = next.removeFirst()
      selected.append(item)
      let date = item.date.addingTimeInterval(Self.nagInterval)
      if DoseWindow.end(for: item.event, among: events).map({ date < $0 }) ?? true {
        next.append(Occurrence(event: item.event, date: date, attempt: item.attempt + 1))
      }
    }
    occurrences = selected.sorted(by: ordered)
    coveredThrough = next.map(\.date).min().map { $0.addingTimeInterval(-1) }
      ?? occurrences.last?.date
  }
}
