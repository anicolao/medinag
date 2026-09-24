import Combine
import FirebaseAuth
import FirebaseFirestore
import Foundation
import MediNagCore
import UserNotifications

@MainActor
final class AppViewModel: ObservableObject {
  struct ReminderPresentation: Equatable {
    let eventID: String
    let medicationName: String
    let scheduledTime: Date
    let reminderNumber: Int
  }

  enum State: Equatable {
    case starting
    case signedOut
    case authenticating
    case choosingSchedule
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
    var lastReconciledAt: Date?
    var patientTimeZone = ""
    var scheduledThrough: Date?
    var nextReminder: Date?
    var expectedPendingCount = 0
    var actualPendingCount = 0
    var missedEventCount = 0
  }

  @Published private(set) var state: State = .starting
  @Published private(set) var availablePlans: [PublishedPlan] = []
  @Published private(set) var currentPlan: PublishedPlan?
  @Published private(set) var schedules: [MedicationSchedule] = []
  @Published private(set) var events: [MedicationEvent] = []
  @Published private(set) var notificationReadiness: NotificationReadiness = .unknown
  @Published private(set) var actionNotice = ""
  @Published private(set) var isWorking = false
  @Published private(set) var activeReminder: ReminderPresentation?
  @Published private(set) var reminderDiagnostics = ReminderDiagnostics()

  private var listeners: [ListenerRegistration] = []
  private var coordinator: DoseCoordinator?
  private var confirmedAccessAdministratorID: String?
  private let directory = FirebasePatientDirectory()
  private let healthReporter: SystemHealthReporter
  private let refreshCoordinator: ReminderRefreshCoordinator
  private let clock: any Clock
  private let notifications: any NotificationScheduling
  private let liveNotifications: LocalNotificationScheduler?
  private var pendingNotificationInteraction: NotificationInteraction?
  private var authenticationDestination: AuthenticationDestination?
  private var authenticationContinuationRequested = false

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
    self.clock = timeline
    self.notifications = notifications
    self.liveNotifications = notifications
    self.healthReporter = healthReporter
    self.refreshCoordinator = ReminderRefreshCoordinator(
      notifications: notifications,
      healthReporter: healthReporter
    )
    installNotificationRouter()
    Task { await boot() }
  }

  var nextEvent: MedicationEvent? {
    events.first { $0.status != .completed }
  }

  var snoozeMinutes: Int {
    currentPlan?.snoozeIntervalMinutes ?? 10
  }

  var maximumReminderCount: Int {
    currentPlan?.maxReminders ?? 3
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
      try await connect(plan: plan)
      actionNotice = "Following \(plan.administratorName)'s schedule."
    } catch {
      actionNotice = error.localizedDescription
      await refreshAvailablePlans()
    }
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
        actionNotice = "Notifications were not enabled."
        await reportIncident(
          code: "notification_authorization_denied",
          message: "The patient iPhone has not allowed medication notifications.",
          severity: "critical"
        )
        return
      }
      try await reconcileNotifications()
      actionNotice = notificationReadiness == .ready
        ? "Notifications are registered with iOS."
        : "Notification permission is enabled, but no future reminders are registered."
    } catch {
      notificationReadiness = .failed
      actionNotice = error.localizedDescription
      await reportIncident(
        code: "notification_reconciliation_failed",
        message: "The patient iPhone could not register its expected reminders.",
        severity: "critical",
        context: ["error": error.localizedDescription]
      )
    }
  }

  func refreshOnForeground() async {
    guard state == .ready, let userID = Auth.auth().currentUser?.uid else { return }
    do {
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

  func respond(_ response: DoseResponse, to event: MedicationEvent) async {
    guard let coordinator else { return }
    isWorking = true
    activeReminder = nil
    defer { isWorking = false }
    do {
      let updated = try await coordinator.respond(response, to: event)
      if let index = events.firstIndex(where: { $0.id == updated.id }) {
        events[index] = updated
      }
      if response == .yesIWill {
        actionNotice = updated.snoozeCount < maximumReminderCount
          ? "Okay. We will remind you again in \(snoozeMinutes) minutes."
          : "Response recorded. The configured reminder limit has been reached."
      } else {
        actionNotice = "Dose complete. Further reminders are cancelled."
      }
    } catch {
      actionNotice = "Could not record that response: \(error.localizedDescription)"
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
        reminderNumber: reminder.reminderNumber
      )
      activeReminder = nil
      actionNotice = "Recording your response…"
      return
    }
    await respond(response, to: event)
  }

  private func boot() async {
    guard FirebaseBootstrap.configure() else {
      state = .configurationMissing
      return
    }
    await refreshNotificationReadiness()
    guard let user = Auth.auth().currentUser else {
      state = .signedOut
      return
    }
    do {
      let destination = try await prepareAuthentication(
        userID: user.uid,
        displayName: user.displayName ?? "Patient",
        email: user.email ?? ""
      )
      try await apply(destination)
    } catch {
      state = .failed(error.localizedDescription)
    }
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

  private func connect(plan: PublishedPlan) async throws {
    disconnectListeners()
    currentPlan = plan
    confirmedAccessAdministratorID = nil
    let repository = FirebaseFollowedPlanRepository(administratorID: plan.id)
    coordinator = DoseCoordinator(
      clock: clock,
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
          self?.events = events
          self?.consumePendingNotificationInteractionIfPossible()
          await self?.scheduleUnfinishedEventsIfReady()
        case .failure(let error): self?.actionNotice = error.localizedDescription
        }
      }
    })
    state = .ready
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
      notificationReadiness == .ready
        || notificationReadiness == .noScheduledReminders
        || notificationReadiness == .failed
    else { return }
    do {
      try await reconcileNotifications()
    } catch {
      notificationReadiness = .failed
      actionNotice = error.localizedDescription
      await reportIncident(
        code: "notification_reconciliation_failed",
        message: "The patient iPhone could not register its expected reminders.",
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
    let result = try await refreshCoordinator.refresh(
      events: events,
      administratorID: plan.id,
      patientID: patientID,
      timeZone: patientTimeZone.identifier,
      snoozeIntervalMinutes: snoozeMinutes,
      maximumReminderCount: maximumReminderCount
    )
    reminderDiagnostics = ReminderDiagnostics(
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

  private func reportIncident(
    code: String,
    message: String,
    severity: String,
    context: [String: String] = [:]
  ) async {
    guard
      let administratorID = currentPlan?.id,
      let patientID = Auth.auth().currentUser?.uid
    else { return }
    await healthReporter.reportIncident(
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

  private func handleNotificationInteraction(_ interaction: NotificationInteraction) {
    switch interaction.kind {
    case .opened:
      activeReminder = ReminderPresentation(
        eventID: interaction.eventID,
        medicationName: interaction.medicationName,
        scheduledTime: interaction.reminderTime,
        reminderNumber: interaction.reminderNumber
      )
    case .response(let response):
      guard events.contains(where: { $0.id == interaction.eventID }) else {
        pendingNotificationInteraction = interaction
        return
      }
      Task { await respond(response, toEventID: interaction.eventID) }
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
}
