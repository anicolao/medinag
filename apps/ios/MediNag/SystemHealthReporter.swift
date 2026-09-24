import FirebaseFirestore
import Foundation

struct ClientSystemIncident: Codable, Sendable {
  let code: String
  let message: String
  let severity: String
  let context: [String: String]
}

final class SystemHealthReporter: @unchecked Sendable {
  private let database: Firestore
  private let fileManager: FileManager
  private let lock = NSLock()

  init(
    database: Firestore = Firestore.firestore(),
    fileManager: FileManager = .default
  ) {
    self.database = database
    self.fileManager = fileManager
  }

  var deviceID: String {
    let key = "medinag.device-id"
    if let existing = UserDefaults.standard.string(forKey: key) {
      return existing
    }
    let value = UUID().uuidString.lowercased()
    UserDefaults.standard.set(value, forKey: key)
    return value
  }

  func reportCoverage(
    administratorID: String,
    patientID: String,
    timeZone: String,
    scheduledThrough: Date,
    expectedPendingCount: Int,
    actualPendingCount: Int,
    ready: Bool
  ) async throws {
    try await database.document(
      "administrators/\(administratorID)/deviceCoverage/\(patientID)"
    ).setData([
      "patientUid": patientID,
      "deviceId": deviceID,
      "timeZone": timeZone,
      "lastRefreshAt": FieldValue.serverTimestamp(),
      "scheduledThrough": Timestamp(date: scheduledThrough),
      "applicationBuild": applicationBuild,
      "reconciliationStatus": ready ? "ready" : "failed",
      "expectedPendingCount": expectedPendingCount,
      "actualPendingCount": actualPendingCount,
      "updatedAt": FieldValue.serverTimestamp(),
    ])
  }

  @discardableResult
  func reportIncident(
    _ incident: ClientSystemIncident,
    administratorID: String,
    patientID: String
  ) async -> Bool {
    do {
      try await submit(
        incident,
        administratorID: administratorID,
        patientID: patientID
      )
      return true
    } catch {
      enqueue(incident)
      return false
    }
  }

  func flushOutbox(administratorID: String, patientID: String) async {
    let pending = loadOutbox()
    guard !pending.isEmpty else { return }
    var remaining: [ClientSystemIncident] = []
    for incident in pending {
      do {
        try await submit(
          incident,
          administratorID: administratorID,
          patientID: patientID
        )
      } catch {
        remaining.append(incident)
      }
    }
    saveOutbox(remaining)
  }

  private func submit(
    _ incident: ClientSystemIncident,
    administratorID: String,
    patientID: String
  ) async throws {
    let safeCode = incident.code.replacingOccurrences(
      of: "[^A-Za-z0-9_-]",
      with: "-",
      options: .regularExpression
    )
    let reference = database.document(
      "administrators/\(administratorID)/systemIncidents/ios-\(deviceID)-\(safeCode)"
    )
    let snapshot = try await reference.getDocument()
    if snapshot.exists {
      try await reference.updateData([
        "lastOccurredAt": FieldValue.serverTimestamp(),
        "occurrenceCount": FieldValue.increment(Int64(1)),
        "context": incident.context,
        "updatedAt": FieldValue.serverTimestamp(),
      ])
    } else {
      try await reference.setData([
        "administratorUid": administratorID,
        "patientUid": patientID,
        "deviceId": deviceID,
        "code": incident.code,
        "message": incident.message,
        "severity": incident.severity,
        "source": "ios",
        "status": "open",
        "firstOccurredAt": FieldValue.serverTimestamp(),
        "lastOccurredAt": FieldValue.serverTimestamp(),
        "occurrenceCount": 1,
        "alertSequence": 1,
        "smsState": "queued",
        "smsAttempts": 0,
        "context": incident.context,
        "updatedAt": FieldValue.serverTimestamp(),
      ])
    }
  }

  private var applicationBuild: String {
    let version = Bundle.main.object(
      forInfoDictionaryKey: "CFBundleShortVersionString"
    ) as? String ?? "unknown"
    let build = Bundle.main.object(
      forInfoDictionaryKey: "CFBundleVersion"
    ) as? String ?? "unknown"
    return "\(version) (\(build))"
  }

  private var outboxURL: URL? {
    fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first?.appendingPathComponent("medinag-incident-outbox.json")
  }

  private func enqueue(_ incident: ClientSystemIncident) {
    lock.withLock {
      var incidents = loadOutboxUnlocked()
      if let index = incidents.firstIndex(where: { $0.code == incident.code }) {
        incidents[index] = incident
      } else {
        incidents.append(incident)
      }
      saveOutboxUnlocked(incidents)
    }
  }

  private func loadOutbox() -> [ClientSystemIncident] {
    lock.withLock { loadOutboxUnlocked() }
  }

  private func saveOutbox(_ incidents: [ClientSystemIncident]) {
    lock.withLock { saveOutboxUnlocked(incidents) }
  }

  private func loadOutboxUnlocked() -> [ClientSystemIncident] {
    guard
      let outboxURL,
      let data = try? Data(contentsOf: outboxURL),
      let incidents = try? JSONDecoder().decode([ClientSystemIncident].self, from: data)
    else { return [] }
    return incidents
  }

  private func saveOutboxUnlocked(_ incidents: [ClientSystemIncident]) {
    guard let outboxURL, let data = try? JSONEncoder().encode(incidents) else { return }
    try? fileManager.createDirectory(
      at: outboxURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try? data.write(to: outboxURL, options: [.atomic, .completeFileProtection])
  }
}
