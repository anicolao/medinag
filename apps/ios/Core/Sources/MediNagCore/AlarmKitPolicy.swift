import Foundation

/// Pure timing/selection rules used by the connected AlarmKit client. Unit
/// tests may use example dates; E2E data still comes from the actual dashboard.
public enum AlarmKitPolicy {
  public static func gridDeadline(origin: Date, now: Date, interval: TimeInterval) -> Date {
    let step = max(1, interval)
    return origin.addingTimeInterval(max(1, floor(now.timeIntervalSince(origin) / step) + 1) * step)
  }

  public static func latestDue(in events: [MedicationEvent], at now: Date) -> MedicationEvent? {
    guard let latest = events.filter({ $0.scheduledTime <= now })
      .max(by: { $0.scheduledTime < $1.scheduledTime }), latest.status != .completed else { return nil }
    return latest
  }

  public static func canCompleteEarly(_ event: MedicationEvent, at now: Date) -> Bool {
    event.status != .completed && event.scheduledTime > now
      && event.scheduledTime.timeIntervalSince(now) <= 900
  }
}
