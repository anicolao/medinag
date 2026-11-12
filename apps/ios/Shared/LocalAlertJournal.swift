import Foundation
import MediNagCore
import OSLog

/// On-device evidence, never a fabricated delivery receipt. Export this file
/// from the application container; it is not exposed in the patient UI.
enum LocalAlertJournal {
  private static let lock = NSLock()
  private static let logger = Logger(subsystem: "org.boardgamescafe.medinag", category: "LocalAlerts")

  static func record(_ type: String, eventID: String? = nil, requestID: String? = nil,
                     deadline: Date? = nil, details: [String: String] = [:]) {
    lock.withLock {
      do {
        let directory = try DurableAlertStorage.directory()
        let file = directory.appendingPathComponent("local-alerts.jsonl")
        var entry = details
        entry["id"] = UUID().uuidString
        entry["type"] = type
        entry["observedAt"] = String(Date().timeIntervalSince1970)
        entry["uptime"] = String(ProcessInfo.processInfo.systemUptime)
        entry["eventID"] = eventID
        entry["requestID"] = requestID
        entry["deadline"] = deadline.map { String($0.timeIntervalSince1970) }
        entry["build"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        #if os(watchOS)
          entry["device"] = "watch"
        #else
          entry["device"] = "phone"
        #endif
        let data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) + Data([10])
        if !FileManager.default.fileExists(atPath: file.path) {
          try Data().write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        // Retain the previous segment too. The journal has bounded storage;
        // it is diagnostic evidence, not an infinite delivery history.
        if let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 8_000_000 {
          let previous = directory.appendingPathComponent("local-alerts.previous.jsonl")
          if FileManager.default.fileExists(atPath: previous.path) { try FileManager.default.removeItem(at: previous) }
          try FileManager.default.moveItem(at: file, to: previous)
          try Data().write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: data); try handle.synchronize()
        logger.info("Local alert evidence: \(type, privacy: .public)")
      } catch {
        logger.fault("Cannot persist local alert evidence: \(error.localizedDescription, privacy: .public)")
      }
    }
  }
}

enum DurableAlertStorage {
  static func directory() throws -> URL {
    let directory = try FileManager.default.url(for: .applicationSupportDirectory,
      in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("LocalAlerts")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  static func save<T: Encodable>(_ value: T, name: String) throws {
    try JSONEncoder().encode(value).write(to: directory().appendingPathComponent(name),
      options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
  }

  static func load<T: Decodable>(_ type: T.Type, name: String) throws -> T? {
    let file = try directory().appendingPathComponent(name)
    guard FileManager.default.fileExists(atPath: file.path) else { return nil }
    return try JSONDecoder().decode(type, from: Data(contentsOf: file))
  }
}

@MainActor
final class LocalResponseOutbox {
  private(set) var responses: [LocalDoseResponse] = []
  private let storageName: String
  init(storageName: String = "responses.json") {
    self.storageName = storageName
    reload()
  }
  func reload() {
    do { responses = try DurableAlertStorage.load([LocalDoseResponse].self, name: storageName) ?? [] }
    catch { LocalAlertJournal.record("response_outbox_read_failed", details: ["error": error.localizedDescription]) }
  }

  func append(_ response: LocalDoseResponse) throws {
    reload()
    guard !responses.contains(where: { $0.id == response.id }) else { return }
    let updated = responses + [response]
    try DurableAlertStorage.save(updated, name: storageName)
    responses = updated
    LocalAlertJournal.record("response_saved_locally", eventID: response.event.id,
      deadline: response.response == .yesIWill ? response.snoozeDeadline : nil,
      details: ["commandID": response.id, "action": response.response.rawValue,
        "tappedAt": String(response.respondedAt.timeIntervalSince1970),
        "latencyFromDose": String(response.respondedAt.timeIntervalSince(response.event.scheduledTime))])
  }

  func remove(_ id: String) throws {
    reload()
    let updated = responses.filter { $0.id != id }
    try DurableAlertStorage.save(updated, name: storageName)
    responses = updated
  }

  func applying(to events: [MedicationEvent], patientID: String, administratorID: String) -> [MedicationEvent] {
    reload()
    var result = events
    for response in responses where response.patientID == patientID && response.administratorID == administratorID {
      if let index = result.firstIndex(where: { $0.id == response.event.id }),
         result[index].status != .completed,
         result[index].hasSameResponseVersion(as: response.event) {
        result[index] = response.updatedEvent
      }
    }
    return result
  }
}
