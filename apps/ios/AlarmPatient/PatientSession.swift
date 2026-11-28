import Combine
@preconcurrency import AlarmKit
import FirebaseAuth
import FirebaseFirestore
import Foundation
import MediNagCore
import Network
import UIKit
import UserNotifications

@MainActor
final class PatientSession: ObservableObject {
  static let shared = PatientSession()
  @Published private(set) var local = PatientAlarmState()
  @Published private(set) var plans: [PublishedPlan] = []
  @Published private(set) var signedIn = false
  @Published private(set) var starting = true
  @Published private(set) var message = ""
  @Published private(set) var busy = false
  #if LOCAL_NOTIFICATION_PATIENT
  @Published private(set) var notificationAuthorized = false
  #endif
  private var listeners: [ListenerRegistration] = []
  private let network = NWPathMonitor()
  private var started = false
  private var flushTask: Task<Void, Never>?
  private var flushRun: UUID?
  private var flushRequested = false
  private var backgroundTask = UIBackgroundTaskIdentifier.invalid
  private var context: PatientAlarmState.Context?
  private var remoteEvents: [MedicationEvent] = []
  private var eventsReceived = false
  private var alarmObserver: Task<Void, Never>?

  init() {
    network.pathUpdateHandler = { [weak self] path in
      guard path.status == .satisfied else { return }
      Task { @MainActor [weak self] in self?.scheduleFlush() }
    }
    network.start(queue: DispatchQueue(label: "medinag.alarmkit-connectivity"))
    NotificationCenter.default.addObserver(forName: .patientAlarmChanged, object: nil, queue: .main) { [weak self] _ in
      Task { @MainActor [weak self] in await self?.reload(); self?.scheduleFlush() }
    }
  }

  func start() async {
    guard !started else { await reload(); scheduleFlush(); return }
    started = true
    #if !LOCAL_NOTIFICATION_PATIENT
    alarmObserver = Task { [weak self] in
      var previous: [UUID: Alarm.State] = [:]
      for await alarms in AlarmManager.shared.alarmUpdates {
        for alarm in alarms where previous[alarm.id] != alarm.state {
          _ = await PatientAlarmEngine.shared.run(.observeOS(alarm.id, String(describing: alarm.state)))
        }
        let removed = previous.keys.filter { id in !alarms.contains(where: { $0.id == id }) }
        for id in removed {
          _ = await PatientAlarmEngine.shared.run(.observeOS(id, "absent from OS inventory; not proof of a medication response"))
        }
        previous = Dictionary(uniqueKeysWithValues: alarms.map { ($0.id, $0.state) })
        #if ALARM_RELIABILITY_TRIAL
        // Best effort when execution is available; ordinary Stop supplies no
        // custom wake handler. The physical trial therefore requires opening
        // the app after Stop rather than promising an automatic next-dose wake.
        if !removed.isEmpty { _ = await PatientAlarmEngine.shared.run(.reconcile) }
        #endif
        self?.scheduleFlush()
      }
    }
    #endif
    defer { starting = false }
    await reload()
    guard FirebaseBootstrap.configure() else { message = "Firebase configuration is missing."; return }
    if let user = Auth.auth().currentUser { await connect(user) }
  }

  func signIn() async {
    busy = true
    message = ""
    defer { busy = false }
    do { await connect(try await GooglePatientAuthenticator.signIn()) }
    catch { message = error.localizedDescription }
  }

  private func connect(_ user: FirebaseAuth.User) async {
    signedIn = true
    do {
      let directory = FirebasePatientDirectory()
      let following = try await directory.ensurePatient(userID: user.uid,
        displayName: user.displayName ?? "Patient", email: user.email ?? "",
        timeZone: TimeZone.autoupdatingCurrent.identifier)
      let available = try await directory.availablePlans(for: user.uid)
      plans = available
      if let following, let plan = available.first(where: { $0.id == following }) {
        await observe(plan, user: user)
      } else if local.context?.patientID == user.uid, let cached = local.context {
        await observe(cached.plan, user: user)
      }
      scheduleFlush()
    } catch {
      // An offline launch must not tear down the cached OS alarm plan.
      message = error.localizedDescription
      if let cached = local.context, cached.patientID == user.uid { await observe(cached.plan, user: user) }
      scheduleFlush()
    }
  }

  func follow(_ plan: PublishedPlan) async {
    guard let user = Auth.auth().currentUser else { return }
    busy = true
    defer { busy = false }
    do {
      try await FirebasePatientDirectory().follow(plan, userID: user.uid,
        displayName: user.displayName ?? "Patient", timeZone: TimeZone.autoupdatingCurrent.identifier)
      await observe(plan, user: user)
    } catch { message = error.localizedDescription }
  }

  private func observe(_ plan: PublishedPlan, user: FirebaseAuth.User) async {
    listeners.forEach { $0.remove() }
    listeners.removeAll()
    let previous = local.context
    let start = previous.flatMap { $0.patientID == user.uid && $0.plan.id == plan.id ? $0.enrolledAt : nil } ?? Date()
    context = .init(patientID: user.uid, plan: plan, enrolledAt: start)
    eventsReceived = false
    let repository = FirebaseFollowedPlanRepository(administratorID: plan.id)
    listeners.append(repository.observeEvents(ignoreEmptyCache: true) { [weak self] result in
      Task { @MainActor [weak self] in
        guard let self else { return }
        switch result {
        case .success(let events):
          self.eventsReceived = true
          self.remoteEvents = events
          await self.importLatest()
        case .failure(let error): self.message = error.localizedDescription
        }
      }
    })
    listeners.append(FirebasePatientDirectory().observeReminderSettings(administratorID: plan.id) { [weak self] snooze, interval in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.context?.plan.snoozeIntervalMinutes = snooze
        self.context?.plan.repeatIntervalMinutes = interval
        await self.importLatest()
      }
    })
    listeners.append(FirebasePatientDirectory().observeAccess(administratorID: plan.id, userID: user.uid) { [weak self] result in
      Task { @MainActor [weak self] in
        guard let self else { return }
        if case .success(false) = result {
          self.local = await PatientAlarmEngine.shared.run(.clear)
          self.context = nil
          self.message = "This schedule is no longer shared with this account."
        }
      }
    })
  }

  private func importLatest() async {
    guard let context, eventsReceived else { return }
    // Permission is obtained from a visible user action, never a Stop handler.
    local = await PatientAlarmEngine.shared.run(.importEvents(context, remoteEvents))
    scheduleFlush()
  }

  func enableAlarms() async {
    do {
      _ = try await PatientAlarmAuthorization.request()
      await importLatest()
      await reload()
    } catch { message = error.localizedDescription }
  }

  func reload() async {
    local = await PatientAlarmEngine.shared.snapshot()
    #if LOCAL_NOTIFICATION_PATIENT
    let settings = await UNUserNotificationCenter.current().notificationSettings()
    notificationAuthorized = settings.authorizationStatus == .authorized
      && settings.alertSetting == .enabled && settings.soundSetting == .enabled
    #if MEDINAG_CRITICAL_ALERTS
    notificationAuthorized = notificationAuthorized && settings.criticalAlertSetting == .enabled
    #endif
    #endif
  }

  func respond(_ response: DoseResponse, eventID: String) async {
    busy = true
    local = await PatientAlarmEngine.shared.run(.respond(eventID, response))
    busy = false
    scheduleFlush()
  }

  func signOut() async {
    local = await PatientAlarmEngine.shared.run(.clear)
    listeners.forEach { $0.remove() }; listeners.removeAll()
    context = nil
    try? Auth.auth().signOut()
    GooglePatientAuthenticator.signOut()
    signedIn = false
  }

  func scheduleFlush() {
    flushRequested = true
    guard flushTask == nil else { return }
    let run = UUID()
    flushRun = run
    backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Report medication responses") { [weak self] in
      Task { @MainActor [weak self] in self?.finishFlush(run: run, cancel: true) }
    }
    flushTask = Task { [weak self] in
      while let self, self.flushRequested, !Task.isCancelled {
        self.flushRequested = false
        if !(await self.flush()) { break }
      }
      self?.finishFlush(run: run, cancel: false)
    }
  }

  private func finishFlush(run: UUID, cancel: Bool) {
    guard flushRun == run else { return }
    if cancel { flushTask?.cancel() }
    if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) }
    backgroundTask = .invalid
    flushTask = nil
    flushRun = nil
  }

  private func flush() async -> Bool {
    guard FirebaseBootstrap.configure(), let user = Auth.auth().currentUser else { return false }
    var snapshot = await PatientAlarmEngine.shared.snapshot()
    guard let context = snapshot.context, user.uid == context.patientID else { return false }
    let repository = FirebaseFollowedPlanRepository(administratorID: context.plan.id)
    do {
      for response in snapshot.responses {
        try Task.checkCancellation()
        guard response.patientID == user.uid, response.administratorID == context.plan.id else { continue }
        _ = try await repository.respond(response.response, to: response.event, at: response.respondedAt)
        snapshot = await PatientAlarmEngine.shared.run(.acknowledgedResponse(response.id))
      }
      let db = Firestore.firestore()
      let evidence = Array(snapshot.evidence.prefix(100))
      if !evidence.isEmpty {
        try await PatientEvidenceRepository.upload(evidence, administratorID: context.plan.id,
          patientID: user.uid, build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")
        snapshot = await PatientAlarmEngine.shared.run(.acknowledgedEvidence(evidence.map(\.id)))
      }
      #if LOCAL_NOTIFICATION_PATIENT
      // No coverage report exists on a fresh install while the permission
      // prompt is unanswered. A migrated old inventory or an actual denied/
      // failed reconciliation has an observation and must invalidate readiness.
      let coverage = snapshot.verificationObservedAt.map { (snapshot.verifiedThrough ?? $0, $0) }
      #else
      let coverage = snapshot.verifiedThrough.flatMap { through in snapshot.verificationObservedAt.map { (through, $0) } }
      #endif
      if let (through, observed) = coverage {
        let count = snapshot.verifiedAlarmIDs.count
        try await db.document("administrators/\(context.plan.id)/deviceCoverage/\(user.uid)").setData([
          "patientUid": user.uid, "deviceId": snapshot.deviceID,
          "timeZone": TimeZone.autoupdatingCurrent.identifier,
          "lastRefreshAt": Timestamp(date: observed), "scheduledThrough": Timestamp(date: through),
          "applicationBuild": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
          "reconciliationStatus": snapshot.lastFailure == nil ? "ready" : "failed",
          "expectedPendingCount": count, "actualPendingCount": count,
          "updatedAt": FieldValue.serverTimestamp(),
        ])
      }
      local = await PatientAlarmEngine.shared.snapshot()
      if !snapshot.responses.isEmpty || !snapshot.evidence.isEmpty {
        flushRequested = true
      }
      return true
    } catch {
      // The durable file remains authoritative until a real server ACK. Offline
      // retries reuse the original response timestamp/version and audit UUIDs.
      message = "Responses are saved on this phone and will synchronize as soon as possible."
      return false
    }
  }
}

/// Firebase executes transactions on its own executor; keep the transaction
/// closure outside UI isolation, just like the existing event repository.
enum PatientEvidenceRepository {
  static func upload(_ evidence: [PatientAlarmState.Evidence], administratorID: String,
    patientID: String, build: String) async throws {
    #if LOCAL_NOTIFICATION_PATIENT
    let engineName = "LocalNotifications"
    let prefix = "local-notifications"
    #else
    let engineName = "AlarmKit"
    let prefix = "alarmkit"
    #endif
    let db = Firestore.firestore()
    _ = try await db.runTransaction { transaction, errorPointer in
      do {
        let refs = evidence.map { db.document("administrators/\(administratorID)/deviceEvents/\($0.id)") }
        let existing = try refs.map { try transaction.getDocument($0) }
        let failures = evidence.filter { $0.kind == "client_failure" }
        let incidentRefs = failures.map { db.document("administrators/\(administratorID)/systemIncidents/\(prefix)-\($0.id)") }
        let incidents = try incidentRefs.map { try transaction.getDocument($0) }
        for (index, event) in evidence.enumerated() where !existing[index].exists {
          transaction.setData([
            "patientUid": patientID, "kind": event.kind, "eventId": event.eventID,
            "observedAt": Timestamp(date: event.observedAt), "detail": event.detail,
            "receivedAt": FieldValue.serverTimestamp(), "build": build,
          ], forDocument: refs[index])
        }
        for (index, failure) in failures.enumerated() where !incidents[index].exists {
          // Create the administrator/SMS incident before ACKing this evidence.
          // Retries use the same UUID and cannot generate another SMS episode.
          transaction.setData([
            "administratorUid": administratorID, "patientUid": patientID,
            "deviceId": "iphone-\(prefix)", "code": "\(prefix)_protection_failed",
            "message": String(failure.detail.prefix(500)), "severity": "critical", "source": "ios",
            "status": "open", "firstOccurredAt": FieldValue.serverTimestamp(),
            "lastOccurredAt": FieldValue.serverTimestamp(), "occurrenceCount": 1,
            "alertSequence": 1, "smsState": "queued", "smsAttempts": 0,
            "context": ["engine": engineName, "evidenceId": failure.id], "updatedAt": FieldValue.serverTimestamp(),
          ], forDocument: incidentRefs[index])
        }
        return nil
      } catch { errorPointer?.pointee = error as NSError; return nil }
    }
  }
}

@MainActor
enum PatientAlarmAuthorization {
  static func request() async throws -> Bool {
    #if LOCAL_NOTIFICATION_PATIENT
    var options: UNAuthorizationOptions = [.alert, .sound]
    #if MEDINAG_CRITICAL_ALERTS
    options.insert(.criticalAlert)
    #endif
    return try await UNUserNotificationCenter.current().requestAuthorization(options: options)
    #else
    try await AlarmManager.shared.requestAuthorization() == .authorized
    #endif
  }
}

#if E2E
enum E2ERuntime {
  static var googleIDToken: String? {
    let args = ProcessInfo.processInfo.arguments
    guard let index = args.firstIndex(of: "-e2e-google-id-token-base64"), index + 1 < args.count,
      let data = Data(base64Encoded: args[index + 1]) else { return nil }
    return String(data: data, encoding: .utf8)
  }
}
#endif
