import Foundation

/// Pending inventory is not a delivery receipt. Exclude elapsed deadlines from
/// the pending-count assertion without pretending the system delivered them.
public struct ReminderInventory: Sendable {
  public let expected: Set<String>
  public let actual: Set<String>
  public var complete: Bool { expected == actual }

  public init(deadlines: [String: Date], pending: Set<String>, at date: Date) {
    expected = Set(deadlines.filter { $0.value > date }.map(\.key))
    actual = pending.intersection(expected)
  }
}
