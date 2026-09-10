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

  private var listeners: [ListenerRegistration] = []
  private var coordinator: DoseCoordinator?
  private var confirmedAccessAdministratorID: String?
  private let directory = FirebasePatientDirectory()
  private let clock: any Clock
  private let notifications: any NotificationScheduling
  private let liveNotifications: LocalNotificationScheduler?
  private var pendingNotificationInteraction: NotificationInteraction?

  static func make() -> AppViewModel { AppViewModel() }

  private init() {
    let notifications = LocalNotificationScheduler()
    #if E2E
      self.clock = E2ERuntime.notificationAccelerationEnabled
        ? E2EReminderClock()
        : SystemClock()
    #else
      self.clock = SystemClock()
    #endif
    self.notifications = notifications
    self.liveNotifications = notifications
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
    defer { isWorking = false }
    do {
      let user = try await GooglePatientAuthenticator.signIn()
      try await finishAuthentication(
        userID: user.uid,
        displayName: user.displayName ?? "Patient",
        email: user.email ?? ""
      )
    } catch {
      try? Auth.auth().signOut()
      GooglePatientAuthenticator.signOut()
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
        displayName: user.displayName ?? "Patient"
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
    state = .signedOut
  }

  func requestNotifications() async {
    guard let coordinator else { return }
    isWorking = true
    defer { isWorking = false }
    do {
      let ready = try await coordinator.requestNotificationReadiness(for: events)
      notificationReadiness = ready ? .ready : .denied
      actionNotice = ready ? "Notifications are ready." : "Notifications were not enabled."
    } catch {
      notificationReadiness = .denied
      actionNotice = error.localizedDescription
    }
  }

  #if E2E
    func advanceReminderClock() {
      _ = LocalNotificationScheduler.deliverAcceleratedNotification()
    }
  #endif

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
    guard let event = events.first(where: { $0.id == eventID }) else { return }
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
      try await finishAuthentication(
        userID: user.uid,
        displayName: user.displayName ?? "Patient",
        email: user.email ?? ""
      )
    } catch {
      state = .failed(error.localizedDescription)
    }
  }

  private func finishAuthentication(
    userID: String,
    displayName: String,
    email: String
  ) async throws {
    async let followingAdministratorID = directory.ensurePatient(
      userID: userID,
      displayName: displayName,
      email: email
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
      try await connect(plan: plan)
      return
    }
    if administratorID != nil {
      try await directory.clearInvalidFollowing(userID: userID)
    }
    availablePlans = plans
    state = .choosingSchedule
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
        case .failure(let error): self?.actionNotice = error.localizedDescription
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
    case .authorized, .provisional, .ephemeral: notificationReadiness = .ready
    case .denied: notificationReadiness = .denied
    case .notDetermined: notificationReadiness = .needsPermission
    @unknown default: notificationReadiness = .unknown
    }
  }

  private func scheduleUnfinishedEventsIfReady() async {
    guard notificationReadiness == .ready, let coordinator else { return }
    do {
      _ = try await coordinator.requestNotificationReadiness(for: events)
    } catch {
      actionNotice = error.localizedDescription
    }
  }

  private func installNotificationRouter() {
    NotificationResponseRouter.shared.handler = { [weak self] interaction in
      self?.handleNotificationInteraction(interaction)
    }
  }

  private func handleNotificationInteraction(_ interaction: NotificationInteraction) {
    guard events.contains(where: { $0.id == interaction.eventID }) else {
      pendingNotificationInteraction = interaction
      return
    }
    switch interaction.kind {
    case .opened:
      #if E2E
        (clock as? E2EReminderClock)?.setNow(interaction.reminderTime)
      #endif
      activeReminder = ReminderPresentation(
        eventID: interaction.eventID,
        medicationName: interaction.medicationName,
        scheduledTime: interaction.reminderTime,
        reminderNumber: interaction.reminderNumber
      )
    case .response(let response):
      Task { await respond(response, toEventID: interaction.eventID) }
    }
  }

  private func consumePendingNotificationInteractionIfPossible() {
    guard let interaction = pendingNotificationInteraction else { return }
    guard events.contains(where: { $0.id == interaction.eventID }) else { return }
    pendingNotificationInteraction = nil
    handleNotificationInteraction(interaction)
  }
}

#if E2E
  private final class E2EReminderClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date()
    var now: Date { lock.withLock { current } }
    func setNow(_ date: Date) { lock.withLock { current = date } }
  }
#endif
