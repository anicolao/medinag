import Foundation

/// Pure timing/selection rules used by the connected AlarmKit client. Unit
/// tests may use example dates; E2E data still comes from the actual dashboard.
public enum AlarmKitPolicy {
  public struct Slot: Sendable, Equatable {
    public let eventID: String
    public let deadline: Date
  }

  /// Whole independent retry blocks, never a lone initial alarm masquerading
  /// as protected coverage. Two slots remain free for replacement/readback.
  public static let alarmBudget = 62
  public static let retryWindow: TimeInterval = 30 * 60

  /// Reliability experiment: original future dose times only. No catch-up,
  /// snooze transformation, or dense retry blocks, even for pending old doses.
  public static func singleDosePlan(events: [MedicationEvent], at now: Date, limit: Int = 1) -> [Slot] {
    Array(events.filter { $0.status != .completed && $0.scheduledTime > now }
      .sorted { $0.scheduledTime < $1.scheduledTime }.prefix(max(0, limit)))
      .map { Slot(eventID: $0.id, deadline: $0.scheduledTime) }
  }

  public static func retryPlan(events: [MedicationEvent], at now: Date,
                               repeatInterval: TimeInterval, budget: Int = alarmBudget) -> [Slot] {
    let ordered = events.sorted { $0.scheduledTime < $1.scheduledTime }
    let latestID = latestDue(in: ordered, at: now)?.id
    let step = max(60, repeatInterval)
    var plan: [Slot] = []
    for (index, event) in ordered.enumerated() where event.status != .completed
      && (event.scheduledTime > now || event.id == latestID) {
      let origin = event.snoozedUntil ?? event.scheduledTime
      let end = max(origin, now).addingTimeInterval(retryWindow)
      let successor = index + 1 < ordered.count ? ordered[index + 1].scheduledTime : .distantFuture
      var date = origin > now ? origin : gridDeadline(origin: origin, now: now, interval: step)
      var block: [Slot] = []
      while date <= end && date < successor {
        block.append(Slot(eventID: event.id, deadline: date))
        date = date.addingTimeInterval(step)
      }
      guard plan.count + block.count <= budget else { break }
      plan.append(contentsOf: block)
    }
    return plan
  }

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
