import AlarmKit
import Foundation

/// Shared with the actual AlarmKit Live Activity extension, not a second timer.
struct PrototypeMetadata: AlarmMetadata {
  let requestedAt: Date
  let deadline: Date
}
