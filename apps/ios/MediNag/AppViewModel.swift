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
  @Published private(set) var schedules: [MedicationSchedule] = []
  @Published private(set) var events: [MedicationEvent] = []
  @Published private(set) var notificationReadiness: NotificationReadiness = .unknown
  @Published private(set) var actionNotice = ""
  @Published private(set) var isWorking = false
  @Published private(set) var activeReminder: ReminderPresentation?

  private var listeners: [ListenerRegistration] = []
  private var coordinator: DoseCoordinator?
  private let clock: any Clock
  private let notifications: any NotificationScheduling
  private let liveNotifications: LocalNotificationScheduler?
  private let snoozeInterval: TimeInterval
  private var pendingNotificationInteraction: NotificationInteraction?

  static func make() -> AppViewModel {
    return AppViewModel()
  }

  private init() {
    let notifications = LocalNotificationScheduler()
    #if E2E
      if E2ERuntime.notificationAccelerationEnabled {
        self.clock = E2EReminderClock()
      } else {
        self.clock = SystemClock()
      }
    #else
      self.clock = SystemClock()
    #endif
    self.notifications = notifications
    self.liveNotifications = notifications
    self.snoozeInterval = DoseCoordinator.defaultSnoozeInterval
    installNotificationRouter()
    Task { await boot() }
  }

  var nextEvent: MedicationEvent? {
    events.first { $0.status != .completed }
  }

  func signIn(email: String, password: String, householdID: String) async {
    let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedHouseholdID = householdID.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    guard
      !normalizedEmail.isEmpty,
      !password.isEmpty,
      !normalizedHouseholdID.isEmpty
    else {
      state = .failed("Enter Steve's email, password, and household ID.")
      return
    }

    isWorking = true
    actionNotice = ""
    defer { isWorking = false }
    do {
      let result = try await Auth.auth().signIn(
        withEmail: normalizedEmail,
        password: password
      )
      try await connect(
        userID: result.user.uid,
        householdID: normalizedHouseholdID
      )
      UserDefaults.standard.set(
        normalizedHouseholdID,
        forKey: Self.householdDefaultsKey
      )
    } catch {
      state = .failed(error.localizedDescription)
    }
  }

  func returnToSignIn() {
    state = .signedOut
    actionNotice = ""
  }

  func signOut() {
    for listener in listeners {
      listener.remove()
    }
    listeners = []
    try? Auth.auth().signOut()
    UserDefaults.standard.removeObject(forKey: Self.householdDefaultsKey)
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
      actionNotice =
        ready
        ? "Notifications are ready."
        : "Notifications were not enabled."
    } catch {
      notificationReadiness = .denied
      actionNotice = error.localizedDescription
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
      actionNotice =
        response == .yesIWill
        ? "Okay. We will remind you again in \(snoozeMinutes) minutes."
        : "Dose complete. Further reminders are cancelled."
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
    guard
      let user = Auth.auth().currentUser,
      let householdID = UserDefaults.standard.string(
        forKey: Self.householdDefaultsKey
      )
    else {
      state = .signedOut
      return
    }
    do {
      try await connect(userID: user.uid, householdID: householdID)
    } catch {
      state = .failed(error.localizedDescription)
    }
  }

  private func connect(userID: String, householdID: String) async throws {
    for listener in listeners {
      listener.remove()
    }
    listeners = []
    let repository = FirebaseSubjectRepository(householdID: householdID)
    try await repository.verifySubjectMembership(userID: userID)
    coordinator = DoseCoordinator(
      clock: clock,
      eventStore: repository,
      notifications: notifications
    )

    listeners.append(
      repository.observeSchedules { [weak self] result in
        Task { @MainActor [weak self] in
          switch result {
          case .success(let schedules):
            self?.schedules = schedules.filter(\.active)
          case .failure(let error):
            self?.actionNotice = error.localizedDescription
          }
        }
      })
    listeners.append(
      repository.observeEvents { [weak self] result in
        Task { @MainActor [weak self] in
          switch result {
          case .success(let events):
            self?.events = events
            self?.consumePendingNotificationInteractionIfPossible()
            await self?.scheduleUnfinishedEventsIfReady()
          case .failure(let error):
            self?.actionNotice = error.localizedDescription
          }
        }
      })
    state = .ready
  }

  private func refreshNotificationReadiness() async {
    guard let liveNotifications else {
      notificationReadiness = .ready
      return
    }
    switch await liveNotifications.authorizationStatus() {
    case .authorized, .provisional, .ephemeral:
      notificationReadiness = .ready
    case .denied:
      notificationReadiness = .denied
    case .notDetermined:
      notificationReadiness = .needsPermission
    @unknown default:
      notificationReadiness = .unknown
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

  private func handleNotificationInteraction(
    _ interaction: NotificationInteraction
  ) {
    guard let event = events.first(where: { $0.id == interaction.eventID }) else {
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
      Task { await respond(response, to: event) }
    }
  }

  private func consumePendingNotificationInteractionIfPossible() {
    guard let interaction = pendingNotificationInteraction else { return }
    guard events.contains(where: { $0.id == interaction.eventID }) else { return }
    pendingNotificationInteraction = nil
    handleNotificationInteraction(interaction)
  }

  private var snoozeMinutes: Int {
    Int(snoozeInterval / 60)
  }

  private static let householdDefaultsKey = "medinag.subject.household-id"
}

#if E2E
  private final class E2EReminderClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date()

    var now: Date {
      lock.withLock { current }
    }

    func setNow(_ date: Date) {
      lock.withLock { current = date }
    }
  }
#endif
