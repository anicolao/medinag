import Combine
import FirebaseAuth
import FirebaseFirestore
import Foundation
import MediNagCore
import Network
import UIKit
import UserNotifications

struct PatientAlertCache: Codable {
  let patientID: String
  let plan: PublishedPlan
  let events: [MedicationEvent]
  var protectionStart: Date? = nil
}

@MainActor
final class AppViewModel: ObservableObject {
  struct ReminderPresentation: Equatable {
    let eventID: String
    let medicationName: String
    let scheduledTime: Date
    let reminderNumber: Int
    let timeZoneIdentifier: String
  }

  enum State: Equatable {
    case starting
    case signedOut
    case authenticating
    case choosingSchedule
    case connectingSchedule
    case ready
    case configurationMissing
    case failed(String)
  }

  enum NotificationReadiness: Equatable {
    case unknown
    case needsPermission
    case ready
    case denied
    case noScheduledReminders
    case failed
  }

  struct ReminderDiagnostics: Equatable {
    var backgroundRefreshRegistered = true
    var lastReconciledAt: Date?
    var patientTimeZone = ""
    var scheduledThrough: Date?
    var nextReminder: Date?
    var expectedPendingCount = 0
    var actualPendingCount = 0
    var missedEventCount = 0
  }

  @Published private(set) var state: State = .starting { didSet { publishWatchSnapshot() } }
  @Published private(set) var availablePlans: [PublishedPlan] = []
  @Published private(set) var currentPlan: PublishedPlan? { didSet { publishWatchSnapshot() } }
  @Published private(set) var schedules: [MedicationSchedule] = []
  @Published private(set) var events: [MedicationEvent] = [] {
    didSet { retireSupersededReminder(); publishWatchSnapshot() }
  }
  @Published private(set) var notificationReadiness: NotificationReadiness = .unknown { didSet { publishWatchSnapshot() } }
  @Published private(set) var actionNotice = ""
  @Published private(set) var isWorking = false
  @Published private(set) var activeReminder: ReminderPresentation? { didSet { publishWatchSnapshot() } }
  @Published private(set) var reminderDiagnostics = ReminderDiagnostics()

  private var listeners: [ListenerRegistration] = []
  private let companionSession = CompanionSession()
  private var initialization: Task<Void, Never>?
  private var localBootFinished = false
  private var localBootWaiters: [CheckedContinuation<Void, Never>] = []
  private var eventsReceived = false
  private var coordinator: DoseCoordinator?
  private var confirmedAccessAdministratorID: String?
  private let directory = FirebasePatientDirectory()
  private let healthReporter: SystemHealthReporter
  private let refreshCoordinator: ReminderRefreshCoordinator
  private let timeline: any NotificationTimeline
  private let notifications: any NotificationScheduling
  private let liveNotifications: LocalNotificationScheduler?
  private var pendingNotificationInteraction: NotificationInteraction?
  private var alarmIDsPresentAtActivation: Set<UUID> = []
  private var activeReconciliation: (
    id: UUID,
    events: [MedicationEvent],
    snoozeMinutes: Int,
    maximumReminderCount: Int,
    task: Task<NotificationReconciliation, Error>
  )?
  private var authenticationDestination: AuthenticationDestination?
  private var authenticationContinuationRequested = false
  private let responseOutbox = LocalResponseOutbox()
  private let networkMonitor = NWPathMonitor()
  private var flushingResponses = false
  private var protectionStart: Date?

  private enum AuthenticationDestination {
    case choosingSchedule([PublishedPlan])
    case ready(PublishedPlan)
  }

  static func make() -> AppViewModel { AppViewModel() }

  private init() {
    #if E2E
      let timeline = E2ERuntime.notificationTimeline()
    #else
      let timeline = SystemNotificationTimeline()
    #endif
    let notifications = LocalNotificationScheduler(timeline: timeline)
    let healthReporter = SystemHealthReporter()
    self.timeline = timeline
    self.notifications = notifications
    self.liveNotifications = notifications
    self.healthReporter = healthReporter
    self.refreshCoordinator = ReminderRefreshCoordinator(
      notifications: notifications,
      healthReporter: healthReporter
    )
    installNotificationRouter()
    NotificationCenter.default.addObserver(forName: .localDoseResponseSaved, object: nil, queue: .main) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self, let patientID = Auth.auth().currentUser?.uid, let plan = currentPlan else { return }
        // The notification handler already saved its updated cache. It must
        // still win if its outbox entry synchronized before this observer ran.
        let cached = try? DurableAlertStorage.load(PatientAlertCache.self, name: "phone-plan.json")
        let source = cached.flatMap { $0.patientID == patientID && $0.plan.id == plan.id ? $0.events : nil } ?? events
        events = responseOutbox.applying(to: source, patientID: patientID, administratorID: plan.id)
        activeReminder = nil
        await flushResponses()
      }
    }
    networkMonitor.pathUpdateHandler = { [weak self] path in
      guard path.status == .satisfied else { return }
      Task { @MainActor [weak self] in
        guard let self else { return }
        await BackgroundReminderRefresh.refreshCachedQueue(reason: "network_restored")
        await flushResponses()
      }
    }
    NotificationCenter.default.addObserver(forName: .localScheduleRefreshed, object: nil, queue: .main) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self, let patientID = Auth.auth().currentUser?.uid,
          let cache = try? DurableAlertStorage.load(PatientAlertCache.self, name: "phone-plan.json"),
          cache.patientID == patientID, cache.plan.id == currentPlan?.id else { return }
        currentPlan = cache.plan
        events = responseOutbox.applying(to: cache.events, patientID: patientID, administratorID: cache.plan.id)
      }
    }
    networkMonitor.start(queue: DispatchQueue(label: "medinag.response-connectivity"))
    companionSession.handleCommand = { [unowned self] command in await handleWatchCommand(command) }
    companionSession.reportFailure = { [weak self] error in
      await self?.reportIncident(code: "watch_sync_failed",
                                message: "The paired Watch schedule synchronization has a persistent or non-retryable failure.",
                                severity: "critical", context: ["error": error])
    }
    companionSession.reportNotificationFailure = { [weak self] error in
      await self?.reportIncident(code: "watch_notification_registration_failed",
        message: "The patient's Watch could not register medication reminders.",
        severity: "critical", context: ["error": error])
    }
    initialization = Task {
      await captureAlertingAlarmsAtActivation()
      await claimAlarmInteractionFromActivation(events: [])
      await boot()
    }
  }

  var nextEvent: MedicationEvent? {
    DoseWindow.nextEvent(in: events, at: timeline.now, snoozeInterval: Double(snoozeMinutes * 60))
  }

  func retireSupersededReminder() {
    guard let reminder = activeReminder else { return }
    guard let event = events.first(where: { $0.id == reminder.eventID }) else {
      activeReminder = nil
      return
    }
    if !DoseWindow.isActive(event, among: events, at: timeline.now) { activeReminder = nil }
  }

  var snoozeMinutes: Int {
    currentPlan?.snoozeIntervalMinutes ?? 10
  }

  var maximumReminderCount: Int {
    currentPlan?.maxReminders ?? 3
  }

  var repeatMinutes: Int { currentPlan?.repeatIntervalMinutes ?? 3 }

  func patientViewDidOpen() {
    retireSupersededReminder()
    if let event = nextEvent, event.scheduledTime <= timeline.now,
      AlertTiming.reminder(for: event, snoozeInterval: Double(snoozeMinutes * 60)) <= timeline.now {
      let presentation = ReminderPresentation(eventID: event.id, medicationName: event.medicationName,
        scheduledTime: event.scheduledTime, reminderNumber: event.snoozeCount + 1,
        timeZoneIdentifier: event.timeZone)
      if activeReminder != presentation { activeReminder = presentation }
    }
  }

  func canCompleteEarly(_ event: MedicationEvent) -> Bool {
    event.scheduledTime > timeline.now && event.scheduledTime.timeIntervalSince(timeline.now) <= 900
      && event.status != .completed
  }

  func signInWithGoogle() async {
    isWorking = true
    actionNotice = ""
    authenticationDestination = nil
    authenticationContinuationRequested = false
    state = .authenticating
    defer { isWorking = false }
    do {
      let user = try await GooglePatientAuthenticator.signIn()
      authenticationDestination = try await prepareAuthentication(
        userID: user.uid,
        displayName: user.displayName ?? "Patient",
        email: user.email ?? ""
      )
      try await revealAuthenticationDestinationIfRequested()
    } catch {
      try? Auth.auth().signOut()
      GooglePatientAuthenticator.signOut()
      authenticationDestination = nil
      authenticationContinuationRequested = false
      state = .failed(error.localizedDescription)
    }
  }

  func continueAfterAuthentication() async {
    authenticationContinuationRequested = true
    actionNotice = "Finishing your secure connection…"
    do {
      try await revealAuthenticationDestinationIfRequested()
    } catch {
      try? Auth.auth().signOut()
      GooglePatientAuthenticator.signOut()
      authenticationDestination = nil
      authenticationContinuationRequested = false
      state = .failed(error.localizedDescription)
    }
  }

  func follow(_ plan: PublishedPlan) async {
    guard let user = Auth.auth().currentUser else {
      state = .signedOut
      return
    }
    isWorking = true
    actionNotice = ""
    defer { isWorking = false }
    do {
      try await directory.follow(
        plan,
        userID: user.uid,
        displayName: user.displayName ?? "Patient",
        timeZone: patientTimeZone.identifier
      )
      try await connect(plan: plan, revealWhenConnected: false)
      actionNotice = "Connected to \(plan.administratorName)'s schedule."
    } catch {
      actionNotice = error.localizedDescription
      await refreshAvailablePlans()
    }
  }

  func continueAfterFollowing() {
    guard state == .connectingSchedule else { return }
    state = .ready
    Task { await requestNotifications() }
  }

  func changeSchedule() async {
    guard
      let user = Auth.auth().currentUser,
      let currentPlan
    else { return }
    isWorking = true
    defer { isWorking = false }
    do {
      for event in events where event.status != .completed {
        await notifications.cancel(eventID: event.id)
      }
      try await directory.leave(currentPlan, userID: user.uid)
      disconnectListeners()
      self.currentPlan = nil
      schedules = []
      events = []
      await refreshAvailablePlans()
      state = .choosingSchedule
    } catch {
      actionNotice = error.localizedDescription
    }
  }

  func returnToSignIn() {
    state = Auth.auth().currentUser == nil ? .signedOut : .choosingSchedule
    actionNotice = ""
  }

  func signOut() {
    disconnectListeners()
    try? Auth.auth().signOut()
    GooglePatientAuthenticator.signOut()
    availablePlans = []
    currentPlan = nil
    schedules = []
    events = []
    authenticationDestination = nil
    authenticationContinuationRequested = false
    state = .signedOut
  }

  func requestNotifications() async {
    guard liveNotifications != nil else { return }
    isWorking = true
    defer { isWorking = false }
    do {
      let authorized = try await notifications.requestAuthorization()
      guard authorized else {
        notificationReadiness = .denied
        let submitted = await reportIncident(
          code: "notification_authorization_denied",
          message: "The patient iPhone has not allowed medication notifications.",
          severity: "critical"
        )
        actionNotice = submitted
          ? "Notifications were not enabled. Your administrator has been alerted."
          : "Notifications were not enabled. Your administrator will be alerted when this iPhone reconnects."
        return
      }
      try await reconcileNotifications()
      actionNotice = notificationReadiness == .ready
        ? "Notifications are registered with iOS."
        : "Notification permission is enabled, but no future reminders are registered."
    } catch {
      print("MediNag notification reconciliation failed: \(error.localizedDescription)")
      notificationReadiness = .failed
      actionNotice = error.localizedDescription
      await reportIncident(
        code: "notification_reconciliation_failed",
        message: "The patient iPhone could not register its expected reminders: \(error.localizedDescription)",
        severity: "critical",
        context: ["error": error.localizedDescription]
      )
    }
  }

  func refreshOnForeground() async {
    // Capture only alarms that were already alerting when this activation
    // occurred. An alarm beginning while MediNag remains foregrounded must not
    // open the response screen until the patient taps the system alarm (or
    // otherwise reopens the app).
    await captureAlertingAlarmsAtActivation()
    guard state == .ready, let userID = Auth.auth().currentUser?.uid else { return }
    patientViewDidOpen()
    Task { await flushResponses() }
    do {
      // Ready local data must be repaired before a timezone/database write can
      // block on connectivity, including while the response screen is open.
      try await reconcileNotifications()
      await claimAlarmInteractionFromActivation(events: events)
      try await directory.updateTimeZone(
        userID: userID,
        timeZone: patientTimeZone.identifier
      )
      await refreshNotificationReadiness()
      await scheduleUnfinishedEventsIfReady()
    } catch {
      actionNotice = "Could not refresh reminders: \(error.localizedDescription)"
      await reportIncident(
        code: "foreground_refresh_failed",
        message: "The patient iPhone could not refresh medication reminders.",
        severity: "critical",
        context: ["error": error.localizedDescription]
      )
    }
  }

  @discardableResult
  func respond(_ response: DoseResponse, to event: MedicationEvent,
               at date: Date? = nil, commandID: String? = nil) async -> Bool {
    let tap = date ?? timeline.now
    guard let patientID = Auth.auth().currentUser?.uid, let plan = currentPlan else { return false }
    if let commandID, responseOutbox.responses.contains(where: { $0.id == commandID }) { return true }
    guard let current = events.first(where: { $0.id == event.id }), current.status != .completed,
      current.hasSameResponseVersion(as: event),
      DoseWindow.isActive(event, among: events, at: timeline.now),
      (response == .yesIDid
        ? AlertTiming.canComplete(event, among: events, at: tap, snoozeInterval: Double(snoozeMinutes * 60))
        : event.scheduledTime <= tap && AlertTiming.reminder(for: event, snoozeInterval: Double(snoozeMinutes * 60)) <= tap)
    else { activeReminder = nil; return false }
    let recorded = LocalDoseResponse(id: commandID ?? UUID().uuidString, patientID: patientID,
      administratorID: plan.id, event: current, response: response, respondedAt: tap,
      snoozeInterval: Double(snoozeMinutes * 60))
    LocalAlertJournal.record("response_tapped", eventID: event.id,
      details: ["action": response.rawValue, "tappedAt": String(tap.timeIntervalSince1970)])
    do {
      try responseOutbox.append(recorded)
      if let index = events.firstIndex(where: { $0.id == event.id }) { events[index] = recorded.updatedEvent }
      try DurableAlertStorage.save(PatientAlertCache(patientID: patientID, plan: plan,
        events: events, protectionStart: protectionStart), name: "phone-plan.json")
      activeReminder = nil
      LocalAlertJournal.record("response_view_state_cleared", eventID: event.id)
      // Network synchronization runs independently; keep the OS response task
      // alive only for the local queue update, never a server round trip.
      Task { await flushResponses() }
      do {
        try await reconcileNotifications()
        LocalAlertJournal.record("response_locally_reconciled", eventID: event.id)
      }
      catch {
        await reportIncident(code: "response_local_scheduling_failed",
          message: "A saved patient response could not update local notifications.", severity: "critical",
          context: ["error": error.localizedDescription])
      }
      return true
    } catch {
      LocalAlertJournal.record("response_save_failed", eventID: event.id, details: ["error": error.localizedDescription])
      await reportIncident(code: "response_local_save_failed", message: "The iPhone could not save a patient response.",
        severity: "critical", context: ["error": error.localizedDescription])
      return false
    }
  }

  private func flushResponses() async {
    guard !flushingResponses, let patientID = Auth.auth().currentUser?.uid,
      let administratorID = currentPlan?.id else { return }
    flushingResponses = true
    defer { flushingResponses = false }
    let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Synchronize medication response")
    defer { if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) } }
    responseOutbox.reload()
    let repository = FirebaseFollowedPlanRepository(administratorID: administratorID)
    for response in responseOutbox.responses where response.patientID == patientID && response.administratorID == administratorID {
      do {
        let confirmed = try await repository.respond(response.response, to: response.event, at: response.respondedAt)
        // Persist the confirmed result before removing the durable intent. A
        // process exit between ACK and listener delivery must not revive it.
        if let index = events.firstIndex(where: { $0.hasSameOccurrence(as: confirmed) }) {
          events[index] = confirmed.preservingResponseProgress(from: events[index])
        }
        if let plan = currentPlan, plan.id == administratorID {
          try DurableAlertStorage.save(PatientAlertCache(patientID: patientID, plan: plan,
            events: events, protectionStart: protectionStart), name: "phone-plan.json")
        }
        try responseOutbox.remove(response.id)
        LocalAlertJournal.record("response_synchronized", eventID: response.event.id, details: ["commandID": response.id])
      } catch is DoseMutationError {
        // A definitive conflicting/newer server version must not revive old
        // notifications. Keep its failure in the audit trail and report it.
        try? responseOutbox.remove(response.id)
        await reportIncident(code: "response_conflict", message: "A saved patient response conflicted with a newer response.",
          severity: "critical", context: ["eventID": response.event.id])
      } catch {
        LocalAlertJournal.record("response_sync_deferred", eventID: response.event.id,
          details: ["error": error.localizedDescription])
        return
      }
    }
  }

  func respond(_ response: DoseResponse, toEventID eventID: String) async {
    guard let event = events.first(where: { $0.id == eventID }) else {
      guard let reminder = activeReminder, reminder.eventID == eventID else { return }
      pendingNotificationInteraction = NotificationInteraction(
        kind: .response(response),
        eventID: reminder.eventID,
        medicationName: reminder.medicationName,
        reminderTime: reminder.scheduledTime,
        reminderNumber: reminder.reminderNumber,
        timeZoneIdentifier: reminder.timeZoneIdentifier
      )
      activeReminder = nil
      actionNotice = "Recording your response…"
      return
    }
    await respond(response, to: event)
  }

  private func boot() async {
    defer { finishLocalBoot() }
    guard FirebaseBootstrap.configure() else {
      state = .configurationMissing
      return
    }
    await refreshNotificationReadiness()
    guard let user = Auth.auth().currentUser else {
      state = .signedOut
      return
    }
    if let cached = try? DurableAlertStorage.load(PatientAlertCache.self, name: "phone-plan.json"),
      cached.patientID == user.uid {
      protectionStart = cached.protectionStart
      try? await connect(plan: cached.plan)
      eventsReceived = true
      events = responseOutbox.applying(to: cached.events, patientID: user.uid, administratorID: cached.plan.id)
      consumePendingNotificationInteractionIfPossible()
      Task { await flushResponses() }
    }
    finishLocalBoot()
    do {
      let destination = try await prepareAuthentication(
        userID: user.uid,
        displayName: user.displayName ?? "Patient",
        email: user.email ?? ""
      )
      try await apply(destination)
    } catch {
      if currentPlan != nil && eventsReceived {
        // A network failure must not replace a usable local alert screen with
        // technical setup/error UI or discard its queued patient responses.
        LocalAlertJournal.record("cached_plan_refresh_deferred", details: ["error": error.localizedDescription])
        await scheduleUnfinishedEventsIfReady()
      } else {
        state = .failed(error.localizedDescription)
      }
    }
  }

  func waitForLocalBoot() async {
    guard !localBootFinished else { return }
    await withCheckedContinuation { localBootWaiters.append($0) }
  }

  private func finishLocalBoot() {
    guard !localBootFinished else { return }
    localBootFinished = true
    let waiters = localBootWaiters
    localBootWaiters.removeAll()
    waiters.forEach { $0.resume() }
  }

  private func prepareAuthentication(
    userID: String,
    displayName: String,
    email: String
  ) async throws -> AuthenticationDestination {
    async let followingAdministratorID = directory.ensurePatient(
      userID: userID,
      displayName: displayName,
      email: email,
      timeZone: patientTimeZone.identifier
    )
    async let discoveredPlans = directory.availablePlans(for: userID)
    let (administratorID, plans) = try await (
      followingAdministratorID,
      discoveredPlans
    )
    if
      let administratorID,
      let plan = plans.first(where: {
        $0.id == administratorID && $0.patientUID == userID
      })
    {
      return .ready(plan)
    }
    if administratorID != nil {
      try await directory.clearInvalidFollowing(userID: userID)
    }
    return .choosingSchedule(plans)
  }

  private func revealAuthenticationDestinationIfRequested() async throws {
    guard
      authenticationContinuationRequested,
      let destination = authenticationDestination
    else { return }
    authenticationDestination = nil
    authenticationContinuationRequested = false
    actionNotice = ""
    try await apply(destination)
  }

  private func apply(_ destination: AuthenticationDestination) async throws {
    switch destination {
    case .choosingSchedule(let plans):
      availablePlans = plans
      state = .choosingSchedule
    case .ready(let plan):
      try await connect(plan: plan)
    }
  }

  private func refreshAvailablePlans() async {
    guard let userID = Auth.auth().currentUser?.uid else { return }
    do {
      availablePlans = try await directory.availablePlans(for: userID)
    } catch {
      actionNotice = error.localizedDescription
      availablePlans = []
    }
  }

  private func connect(
    plan: PublishedPlan,
    revealWhenConnected: Bool = true
  ) async throws {
    disconnectListeners()
    currentPlan = plan
    if protectionStart == nil {
      // A first enrollment starts prospectively. An upgrade with already
      // registered reminders must preserve its current alert instead.
      let registered = UserDefaults.standard.dictionary(forKey: "medinag.actionable.registered-versions") ?? [:]
      protectionStart = registered.isEmpty ? timeline.now : .distantPast
    }
    confirmedAccessAdministratorID = nil
    let repository = FirebaseFollowedPlanRepository(administratorID: plan.id)
    coordinator = DoseCoordinator(
      clock: timeline,
      eventStore: repository,
      notifications: notifications,
      snoozeInterval: TimeInterval(plan.snoozeIntervalMinutes * 60),
      maximumReminderCount: plan.maxReminders
    )
    if let userID = Auth.auth().currentUser?.uid {
      let administratorID = plan.id
      listeners.append(directory.observeAccess(
        administratorID: administratorID,
        userID: userID
      ) { [weak self] result in
        Task { @MainActor [weak self] in
          switch result {
          case .success(true): self?.confirmedAccessAdministratorID = administratorID
          case .success(false) where self?.confirmedAccessAdministratorID == administratorID:
            await self?.handlePlanUnavailable()
          case .success(false): break
          case .failure(let error): self?.actionNotice = error.localizedDescription
          }
        }
      })
    }
    listeners.append(repository.observeSchedules { [weak self] result in
      Task { @MainActor [weak self] in
        switch result {
        case .success(let schedules): self?.schedules = schedules.filter(\.active)
        case .failure(let error):
          self?.actionNotice = error.localizedDescription
          await self?.reportIncident(
            code: "firestore_event_sync_failed",
            message: "The patient iPhone could not synchronize medication events.",
            severity: "critical",
            context: ["error": error.localizedDescription]
          )
        }
      }
    })
    listeners.append(repository.observeEvents { [weak self] result in
      Task { @MainActor [weak self] in
        switch result {
        case .success(let events):
          self?.eventsReceived = true
          if let self, let patientID = Auth.auth().currentUser?.uid {
            let eligible = events.filter { $0.scheduledTime >= (protectionStart ?? .distantPast) }
            let prepared = AlertTiming.applyingPolicy(to: eligible, previous: self.events,
              at: timeline.now, snoozeInterval: Double(snoozeMinutes * 60), repeatInterval: Double(repeatMinutes * 60))
            self.events = responseOutbox.applying(to: prepared, patientID: patientID, administratorID: plan.id)
            try? DurableAlertStorage.save(PatientAlertCache(patientID: patientID,
              plan: currentPlan ?? plan, events: self.events, protectionStart: protectionStart), name: "phone-plan.json")
            Task { await self.flushResponses() }
          }
          await self?.claimAlarmInteractionFromActivation(events: events)
          self?.consumePendingNotificationInteractionIfPossible()
          await self?.scheduleUnfinishedEventsIfReady()
        case .failure(let error): self?.actionNotice = error.localizedDescription
        }
      }
    })
    listeners.append(directory.observeReminderSettings(administratorID: plan.id) { [weak self] snooze, repeatMinutes in
      Task { @MainActor [weak self] in
        self?.currentPlan?.repeatIntervalMinutes = repeatMinutes
        self?.currentPlan?.snoozeIntervalMinutes = snooze
        if let self {
          events = AlertTiming.applyingPolicy(to: events, previous: events, at: timeline.now,
            snoozeInterval: Double(snooze * 60), repeatInterval: Double(repeatMinutes * 60))
        }
        await self?.scheduleUnfinishedEventsIfReady()
      }
    })
    if AppDelegate.reminderRefreshRegistrationSucceeded == false {
      reminderDiagnostics.backgroundRefreshRegistered = false
      notificationReadiness = .failed
      actionNotice = "Daily background reminder refresh could not be registered. Your administrator has been alerted."
      await reportIncident(
        code: "background_refresh_registration_failed",
        message: "The patient iPhone could not register its daily background reminder refresh task.",
        severity: "critical"
      )
    }
    state = revealWhenConnected ? .ready : .connectingSchedule
    if notificationReadiness == .denied {
      await reportIncident(
        code: "notification_authorization_denied",
        message: "The patient iPhone has disabled medication notifications.",
        severity: "critical"
      )
    }
  }

  private func handlePlanUnavailable() async {
    guard let previousPlan = currentPlan else { return }
    for event in events where event.status != .completed {
      await notifications.cancel(eventID: event.id)
    }
    disconnectListeners()
    currentPlan = nil
    schedules = []
    events = []
    if let userID = Auth.auth().currentUser?.uid {
      try? await directory.clearInvalidFollowing(userID: userID)
      await refreshAvailablePlans()
    }
    actionNotice = "\(previousPlan.administratorName)'s schedule is no longer available. Choose a new schedule."
    state = .choosingSchedule
  }

  private func disconnectListeners() {
    eventsReceived = false
    for listener in listeners { listener.remove() }
    listeners = []
    coordinator = nil
    confirmedAccessAdministratorID = nil
  }

  private func refreshNotificationReadiness() async {
    guard let liveNotifications else {
      notificationReadiness = .ready
      return
    }
    switch await liveNotifications.authorizationStatus() {
    case .authorized, .provisional, .ephemeral:
      notificationReadiness = .noScheduledReminders
    case .denied: notificationReadiness = .denied
    case .notDetermined: notificationReadiness = .needsPermission
    @unknown default: notificationReadiness = .unknown
    }
  }

  private func scheduleUnfinishedEventsIfReady() async {
    guard
      !isWorking,
      notificationReadiness == .ready
        || notificationReadiness == .noScheduledReminders
        || notificationReadiness == .failed
    else { return }
    do {
      try await reconcileNotifications()
    } catch {
      print("MediNag notification reconciliation failed: \(error.localizedDescription)")
      notificationReadiness = .failed
      actionNotice = error.localizedDescription
      await reportIncident(
        code: "notification_reconciliation_failed",
        message: "The patient iPhone could not register its expected reminders: \(error.localizedDescription)",
        severity: "critical",
        context: ["error": error.localizedDescription]
      )
    }
  }

  private func reconcileNotifications() async throws {
    guard
      liveNotifications != nil,
      let plan = currentPlan,
      let patientID = Auth.auth().currentUser?.uid
    else { return }
    if let activeReconciliation {
      if
        activeReconciliation.events == events,
        activeReconciliation.snoozeMinutes == snoozeMinutes,
        activeReconciliation.maximumReminderCount == maximumReminderCount
      {
        let result = try await activeReconciliation.task.value
        applyReconciliation(result)
        return
      }
      _ = try await activeReconciliation.task.value
      if self.activeReconciliation?.id == activeReconciliation.id {
        self.activeReconciliation = nil
      }
      return try await reconcileNotifications()
    }
    let reconciliationID = UUID()
    let capturedEvents = events
    let capturedSnoozeMinutes = snoozeMinutes
    let capturedMaximumReminderCount = maximumReminderCount
    let task = Task {
      try await refreshCoordinator.refresh(
        events: capturedEvents,
        administratorID: plan.id,
        patientID: patientID,
        timeZone: patientTimeZone.identifier,
        snoozeIntervalMinutes: capturedSnoozeMinutes,
        maximumReminderCount: capturedMaximumReminderCount,
        repeatIntervalMinutes: repeatMinutes
      )
    }
    activeReconciliation = (
      reconciliationID,
      capturedEvents,
      capturedSnoozeMinutes,
      capturedMaximumReminderCount,
      task
    )
    defer {
      if activeReconciliation?.id == reconciliationID {
        activeReconciliation = nil
      }
    }
    let result = try await task.value
    applyReconciliation(result)
  }

  private func applyReconciliation(_ result: NotificationReconciliation) {
    reminderDiagnostics = ReminderDiagnostics(
      backgroundRefreshRegistered: AppDelegate.reminderRefreshRegistrationSucceeded != false,
      lastReconciledAt: Date(),
      patientTimeZone: patientTimeZone.identifier,
      scheduledThrough: result.scheduledThrough,
      nextReminder: result.nextReminder,
      expectedPendingCount: result.expectedPendingCount,
      actualPendingCount: result.actualPendingCount,
      missedEventCount: result.missedEventIDs.count
    )
    notificationReadiness = result.expectedPendingCount > 0
      && result.actualPendingCount == result.expectedPendingCount
      ? .ready
      : .noScheduledReminders
    if !result.missedEventIDs.isEmpty {
      actionNotice = "A medication time was missed before this iPhone could register it."
    }
  }

  @discardableResult
  private func reportIncident(
    code: String,
    message: String,
    severity: String,
    context: [String: String] = [:]
  ) async -> Bool {
    guard
      let administratorID = currentPlan?.id,
      let patientID = Auth.auth().currentUser?.uid
    else { return false }
    return await healthReporter.reportIncident(
      ClientSystemIncident(
        code: code,
        message: message,
        severity: severity,
        context: context
      ),
      administratorID: administratorID,
      patientID: patientID
    )
  }

  private func installNotificationRouter() {
    NotificationResponseRouter.shared.handler = { [weak self] interaction in
      self?.handleNotificationInteraction(interaction)
    }
  }

  private func claimAlarmInteractionFromActivation(
    events: [MedicationEvent]
  ) async {
    guard !alarmIDsPresentAtActivation.isEmpty else { return }
    let candidateIDs = alarmIDsPresentAtActivation
    if let interaction = await liveNotifications?.claimAlarmInteraction(
      events: events,
      candidateAlarmIDs: candidateIDs
    ) {
      alarmIDsPresentAtActivation.removeAll()
      handleNotificationInteraction(interaction)
    }
  }

  private func captureAlertingAlarmsAtActivation() async {
    let alertingIDs = await liveNotifications?.alertingAlarmIDs() ?? []
    alarmIDsPresentAtActivation.formUnion(alertingIDs)
  }

  private func handleNotificationInteraction(_ interaction: NotificationInteraction) {
    switch interaction.kind {
    case .opened:
      guard let event = events.first(where: { $0.id == interaction.eventID }) else {
        if !eventsReceived { pendingNotificationInteraction = interaction }
        return
      }
      guard DoseWindow.isActive(event, among: events, at: timeline.now),
        AlertTiming.reminder(for: event, snoozeInterval: Double(snoozeMinutes * 60)) <= timeline.now
      else {
        LocalAlertJournal.record("obsolete_notification_opened", eventID: event.id)
        return
      }
      timeline.didReceiveNotification(at: interaction.reminderTime)
      activeReminder = ReminderPresentation(
        eventID: interaction.eventID,
        medicationName: interaction.medicationName,
        scheduledTime: interaction.reminderTime,
        reminderNumber: interaction.reminderNumber,
        timeZoneIdentifier: interaction.timeZoneIdentifier
      )
    case .response(let response):
      guard let event = events.first(where: { $0.id == interaction.eventID }) else {
        pendingNotificationInteraction = interaction
        return
      }
      guard event.status != .completed, event.snoozeCount + 1 == interaction.reminderNumber else {
        actionNotice = "This dose was already answered. Showing the current schedule."
        return
      }
      Task { await respond(response, to: event) }
    }
  }

  private func consumePendingNotificationInteractionIfPossible() {
    guard let interaction = pendingNotificationInteraction else { return }
    guard events.contains(where: { $0.id == interaction.eventID }) else { return }
    pendingNotificationInteraction = nil
    handleNotificationInteraction(interaction)
  }

  private var patientTimeZone: TimeZone {
    #if E2E
      E2ERuntime.reminderTimeZone
    #else
      .autoupdatingCurrent
    #endif
  }

  private func watchSnapshot() -> CompanionSnapshot {
    let connected = (state == .ready || state == .connectingSchedule) && currentPlan != nil
    // Bound the WatchConnectivity payload without letting old completion
    // history crowd out the upcoming doses.
    let latestDue = events.filter { $0.scheduledTime <= timeline.now }.map(\.scheduledTime).max()
    // Include completed doses at the current boundary: they still supersede
    // older unanswered doses. Old history must not crowd upcoming doses out.
    let sharedEvents = Array(events.filter { event in
      latestDue.map { event.scheduledTime >= $0 } ?? true
    }.prefix(48))
    return CompanionSnapshot(
      patientID: connected ? Auth.auth().currentUser?.uid : nil,
      administratorID: connected ? currentPlan?.id : nil,
      administratorName: connected ? currentPlan?.administratorName ?? "" : "",
      planName: connected ? currentPlan?.planName ?? "" : "",
      events: connected ? sharedEvents : [],
      snoozeMinutes: snoozeMinutes, maximumReminderCount: maximumReminderCount,
      ready: connected && eventsReceived,
      readinessMessage: connected
        ? (!eventsReceived ? "Synchronizing doses with iPhone…" :
            (notificationReadiness == .failed || notificationReadiness == .denied
              ? "Check notification readiness on iPhone"
              : notificationReadiness == .needsPermission
                ? "Allow notifications on iPhone" : "Independent notifications on both devices"))
        : "Sign in and choose your schedule in MediNag on iPhone.",
      logicalDate: timeline.now, realDate: Date(), clockScale: timeline.realSecondsPerLogicalSecond,
      scheduleCleared: state == .signedOut || state == .choosingSchedule,
      repeatMinutes: repeatMinutes
    )
  }

  private func publishWatchSnapshot() {
    // A cold start is not a sign-out. Keep the Watch's OS-owned notifications
    // intact until real data or an authoritative relationship change arrives.
    switch state {
    case .ready: guard eventsReceived else { return }
    case .signedOut, .choosingSchedule: break
    default: return
    }
    companionSession.publish(watchSnapshot())
  }

  private func handleWatchCommand(_ command: CompanionCommand) async -> CompanionReply {
    LocalAlertJournal.record("watch_command_received", eventID: command.event?.id,
      details: ["commandID": command.identifier, "action": command.response?.rawValue ?? "refresh"])
    // A background response needs the cached identity/plan, not completion of
    // an Auth/Firestore round trip that might outlast the OS execution slot.
    await waitForLocalBoot()
    guard let response = command.response else {
      guard state == .ready || state == .signedOut || state == .choosingSchedule else {
        return CompanionReply(snapshot: watchSnapshot(), accepted: false,
          message: "iPhone reconnecting. Last synced reminders remain active.", retryable: true)
      }
      if state == .ready, let plan = currentPlan {
        do {
          let refreshed = try await FirebaseFollowedPlanRepository(administratorID: plan.id)
            .fetchEvents(source: .server)
          eventsReceived = true
          let prepared = AlertTiming.applyingPolicy(to: refreshed, previous: events,
            at: timeline.now, snoozeInterval: Double(snoozeMinutes * 60), repeatInterval: Double(repeatMinutes * 60))
          if let patientID = Auth.auth().currentUser?.uid {
            events = responseOutbox.applying(to: prepared, patientID: patientID, administratorID: plan.id)
            try DurableAlertStorage.save(PatientAlertCache(patientID: patientID, plan: plan,
              events: events, protectionStart: protectionStart), name: "phone-plan.json")
          }
        } catch {
          await reportIncident(code: "watch_refresh_failed",
                               message: "The iPhone could not refresh the paired Watch's medication events.",
                               severity: "critical", context: ["error": error.localizedDescription])
          return CompanionReply(snapshot: watchSnapshot(), accepted: false,
                                message: "Could not refresh from the server. Check MediNag on iPhone.", retryable: true)
        }
      }
      return CompanionReply(snapshot: watchSnapshot(), accepted: true, message: "")
    }
    guard state == .ready, !isWorking else {
      return CompanionReply(snapshot: watchSnapshot(), accepted: false,
        message: "iPhone is reconnecting or saving another response. Retry your choice.", retryable: true)
    }
    if command.patientID == Auth.auth().currentUser?.uid, command.administratorID == currentPlan?.id,
      let expected = command.event, let current = events.first(where: { $0.hasSameOccurrence(as: expected) }),
      current.status != .completed, response == .yesIWill, current.snoozeCount < expected.snoozeCount {
      return CompanionReply(snapshot: watchSnapshot(), accepted: false,
        message: "Waiting for the earlier queued response.", retryable: true)
    }
    guard
          command.patientID == Auth.auth().currentUser?.uid,
          command.administratorID == currentPlan?.id,
          let expected = command.event,
          let event = events.first(where: { $0.id == expected.id }),
          (event.hasSameResponseVersion(as: expected) || response == .yesIDid && event.hasSameOccurrence(as: expected)),
          watchSnapshot().canRespond(to: event) else {
      return CompanionReply(snapshot: watchSnapshot(), accepted: false,
                            message: "Dose or connection changed. Refresh and check your schedule.")
    }
    let accepted = await respond(response, to: event, at: command.respondedAt, commandID: command.identifier)
    if !accepted {
      await reportIncident(code: "watch_response_failed",
                           message: "The paired Apple Watch could not confirm a medication response.",
                           severity: "critical", context: ["eventID": event.id, "error": actionNotice])
    }
    publishWatchSnapshot()
    return CompanionReply(snapshot: watchSnapshot(), accepted: accepted, message: actionNotice,
      retryable: !accepted)
  }
}
