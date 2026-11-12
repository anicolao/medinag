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
      AlertTiming.reminder(for: event, snoozeInterval: snoozeInterval)
    }
    let eligible = events.filter { isActive($0, among: events, at: now) }
    // An unanswered due alert wins over any future dose, even if snoozed past
    // that future dose. A completed latest dose still retires all older ones.
    if let due = eligible.filter({ $0.scheduledTime <= now && reminder($0) <= now })
      .max(by: { $0.scheduledTime < $1.scheduledTime }) { return due }
    return eligible.filter { $0.scheduledTime > now }.min {
      if $0.scheduledTime == $1.scheduledTime { return $0.id < $1.id }
      return $0.scheduledTime < $1.scheduledTime
    }
  }
}
