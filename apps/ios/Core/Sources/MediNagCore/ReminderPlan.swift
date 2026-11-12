import Foundation

/// Protect complete 30-minute dose windows before considering farther doses.
/// No response or background wake is needed to move between preloaded windows.
public struct ReminderPlan: Sendable {
  public static let nagInterval: TimeInterval = 3 * 60
  public static let capacity = 60
  public static let protectionWindow: TimeInterval = 30 * 60

  public struct Occurrence: Sendable {
    public let event: MedicationEvent
    public let date: Date
    public let attempt: Int
    public var identifier: String {
      "medinag.dose.\(event.id).v\(event.snoozeCount).\(Int(date.timeIntervalSince1970)).\(attempt)"
    }
  }

  public let occurrences: [Occurrence]
  /// Earliest omitted critical request minus one second, or the end of the
  /// last fully protected window. Deliberate gaps between windows are not faults.
  public let coveredThrough: Date?
  public let protectedEventIDs: Set<String>
  public let requiredPairCovered: Bool
  public let requiredPairRequestCount: Int

  /// A request already handed to the OS must not be deleted just because its
  /// logical deadline passed before the OS consumed it. This retains an actual
  /// pending request only; it never creates/replays a past notification.
  public static func retainsInFlight(_ queued: MedicationEvent, deadline: Date,
    among events: [MedicationEvent], now: Date, snoozeInterval: TimeInterval) -> Bool {
    guard deadline <= now, let current = events.first(where: { $0.hasSameResponseVersion(as: queued) }),
      DoseWindow.isActive(current, among: events, at: now) else { return false }
    return deadline >= AlertTiming.reminder(for: current, snoozeInterval: snoozeInterval)
  }

  public init(events: [MedicationEvent], now: Date, snoozeInterval: TimeInterval,
              repeatInterval: TimeInterval = Self.nagInterval, capacity: Int = Self.capacity) {
    let limit = max(0, capacity)
    let active = events.filter { DoseWindow.isActive($0, among: events, at: now) }
      .sorted { $0.scheduledTime == $1.scheduledTime ? $0.id < $1.id : $0.scheduledTime < $1.scheduledTime }
    func ordered(_ a: Occurrence, _ b: Occurrence) -> Bool {
      a.date == b.date ? a.identifier < b.identifier : a.date < b.date
    }
    func block(_ event: MedicationEvent) -> [Occurrence] {
      let cadence = max(1, event.repeatIntervalSeconds ?? repeatInterval)
      let start = AlertTiming.reminder(for: event, snoozeInterval: snoozeInterval)
      // An explicit snooze still gets its expiry alert even if the patient
      // snoozed beyond the normal protection window. It cannot outlive a successor.
      let end = max(event.scheduledTime.addingTimeInterval(Self.protectionWindow), start)
      let cutoff = DoseWindow.end(for: event, among: events)
      var attempt = start >= now ? 0 : max(1, Int(floor(now.timeIntervalSince(start) / cadence)) + 1)
      var result: [Occurrence] = []
      while result.count <= limit {
        let date = start.addingTimeInterval(Double(attempt) * cadence)
        guard date <= end, cutoff.map({ date < $0 }) ?? true else { break }
        result.append(Occurrence(event: event, date: date, attempt: attempt))
        attempt += 1
      }
      return result
    }
    let blocks = active.map { ($0, block($0)) }
    let pair = Array(blocks.prefix(2))
    requiredPairRequestCount = pair.reduce(0) { $0 + $1.1.count }
    requiredPairCovered = requiredPairRequestCount <= limit
    var selected: [Occurrence] = []
    var protected: Set<String> = []
    if requiredPairCovered {
      for (event, requests) in pair {
        selected += requests
        protected.insert(event.id)
      }
    } else {
      // Unsafe settings must not silently starve the next initial alert.
      // Best effort alternates between both windows and reports insufficient
      // protection explicitly; it does NOT claim two complete windows.
      let longest = pair.map { $0.1.count }.max() ?? 0
      for index in 0..<longest {
        for (_, requests) in pair where index < requests.count && selected.count < limit {
          selected.append(requests[index])
        }
      }
    }
    // Fit only complete further windows; never spend all slots on one dose.
    for (event, requests) in blocks.dropFirst(2) {
      if selected.count + requests.count <= limit {
        selected += requests
        protected.insert(event.id)
      } else { break }
    }
    occurrences = selected.sorted(by: ordered)
    protectedEventIDs = protected
    let selectedIDs = Set(selected.map(\.identifier))
    let firstOmitted = blocks.flatMap { $0.1 }.filter { !selectedIDs.contains($0.identifier) }.map(\.date).min()
    coveredThrough = firstOmitted.map { $0.addingTimeInterval(-1) }
      ?? blocks.filter { protected.contains($0.0.id) && !$0.1.isEmpty }
        .map { max($0.0.scheduledTime.addingTimeInterval(Self.protectionWindow),
                   AlertTiming.reminder(for: $0.0, snoozeInterval: snoozeInterval)) }.max()
  }
}

/// Preferred times are requests, never wake-up guarantees. Re-request from
/// actual execution opportunities without pushing an already-earlier request out.
public enum ReminderRefreshPolicy {
  public static func preferredDate(now: Date, events: [MedicationEvent], coveredThrough: Date? = nil) -> Date {
    var candidates = [now.addingTimeInterval(15 * 60)]
    if let next = events.map(\.scheduledTime).filter({ $0 > now }).min() {
      candidates.append(next.addingTimeInterval(-5 * 60))
    }
    if let coveredThrough { candidates.append(coveredThrough.addingTimeInterval(-15 * 60)) }
    return max(now.addingTimeInterval(1), candidates.min()!)
  }
}
