import Foundation

/// The next scheduled time supersedes the previous dose group. Completion is
/// deliberately irrelevant: taking the noon dose early still retires 10 AM
/// only at noon, and a completed noon dose still retires an unanswered 10 AM.
public enum DoseWindow {
  public static func end(for event: MedicationEvent, among events: [MedicationEvent]) -> Date? {
    events.lazy.map(\.scheduledTime).filter { $0 > event.scheduledTime }.min()
  }

  public static func isActive(_ event: MedicationEvent, among events: [MedicationEvent], at now: Date) -> Bool {
    event.status != .completed && (end(for: event, among: events).map { now < $0 } ?? true)
  }

  public static func nextEvent(in events: [MedicationEvent], at now: Date,
                               snoozeInterval: TimeInterval) -> MedicationEvent? {
    func reminder(_ event: MedicationEvent) -> Date {
      event.status == .snoozed
        ? (event.lastSnoozedAt ?? event.scheduledTime).addingTimeInterval(snoozeInterval)
        : event.scheduledTime
    }
    return events.filter { isActive($0, among: events, at: now) }.min {
      if reminder($0) == reminder($1) { return $0.id < $1.id }
      return reminder($0) < reminder($1)
    }
  }
}
