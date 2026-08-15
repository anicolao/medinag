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
  private let notifications: any NotificationScheduling
  private let liveNotifications: LocalNotificationScheduler?
  private let fixture: Bool
  private let snoozeInterval: TimeInterval

  static func make() -> AppViewModel {
    let fixtureName = ProcessInfo.processInfo.arguments.value(after: "-e2e-fixture")
    if fixtureName == "scheduled-dose-first-reminder" {
      let event = Self.pendingDoseFixture()
      return AppViewModel(
        fixture: event,
        now: event.scheduledTime,
        reminderTime: event.scheduledTime,
        reminderNumber: 1
      )
    }
    if fixtureName == "scheduled-dose-repeat-due" {
      let event = Self.snoozedDoseFixture()
      let repeatTime = event.scheduledTime.addingTimeInterval(Self.fixtureSnoozeInterval)
      return AppViewModel(
        fixture: event,
        now: repeatTime,
        reminderTime: repeatTime,
        reminderNumber: 2
      )
    }
    return AppViewModel()
  }

  private init() {
    let notifications = LocalNotificationScheduler()
    self.notifications = notifications
    self.liveNotifications = notifications
    self.fixture = false
    self.snoozeInterval = Self.fixtureSnoozeInterval
    installNotificationRouter()
    Task { await boot() }
  }

  private init(
    fixture: MedicationEvent,
    now: Date,
    reminderTime: Date,
    reminderNumber: Int
  ) {
    let eventStore = FixtureEventStore(event: fixture)
    let notifications = FixtureNotificationScheduler()
    self.notifications = notifications
    self.liveNotifications = nil
    self.fixture = true
    self.snoozeInterval = Self.fixtureSnoozeInterval
    self.events = [fixture]
    self.schedules = [
      MedicationSchedule(
        id: fixture.scheduleID,
        medicationName: fixture.medicationName,
        scheduledTime: "08:00",
        daysOfWeek: [1, 2, 3, 4, 5, 6, 7],
        active: true
      )
    ]
    self.notificationReadiness = .ready
    self.coordinator = DoseCoordinator(
      clock: FixedFixtureClock(now: now),
      eventStore: eventStore,
      notifications: notifications,
      snoozeInterval: snoozeInterval
    )
    self.activeReminder = ReminderPresentation(
      eventID: fixture.id,
      medicationName: fixture.medicationName,
      scheduledTime: reminderTime,
      reminderNumber: reminderNumber
    )
    self.state = .ready
    installNotificationRouter()
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
      clock: SystemClock(),
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
    NotificationResponseRouter.shared.handler = { [weak self] response in
      guard
        let self,
        let event = self.events.first(where: { $0.id == response.eventID })
      else {
        return
      }
      Task { await self.respond(response.response, to: event) }
    }
  }

  private static func pendingDoseFixture() -> MedicationEvent {
    MedicationEvent(
      id: "morning-dose",
      scheduleID: "morning-schedule",
      medicationName: "Morning Prescription Doses",
      scheduledTime: Date(timeIntervalSince1970: 1_785_758_400),
      status: .pending,
      snoozeCount: 0
    )
  }

  private static func snoozedDoseFixture() -> MedicationEvent {
    var event = pendingDoseFixture()
    event.status = .snoozed
    event.snoozeCount = 1
    event.lastSnoozedAt = event.scheduledTime
    return event
  }

  private var snoozeMinutes: Int {
    Int(snoozeInterval / 60)
  }

  private static let householdDefaultsKey = "medinag.subject.household-id"
  private static let fixtureSnoozeInterval = DoseCoordinator.defaultSnoozeInterval
}

private struct FixedFixtureClock: Clock {
  let now: Date
}

private actor FixtureEventStore: MedicationEventStore {
  private var event: MedicationEvent

  init(event: MedicationEvent) {
    self.event = event
  }

  func snooze(eventID: String, at date: Date) async throws -> MedicationEvent {
    event.status = .snoozed
    event.snoozeCount += 1
    event.lastSnoozedAt = date
    return event
  }

  func complete(eventID: String, at date: Date) async throws -> MedicationEvent {
    event.status = .completed
    event.completedAt = date
    return event
  }
}

private actor FixtureNotificationScheduler: NotificationScheduling {
  func requestAuthorization() async throws -> Bool { true }
  func schedule(event: MedicationEvent) async throws {}
  func scheduleRepeat(for event: MedicationEvent, at date: Date) async throws {}
  func cancel(eventID: String) async {}
}

extension Array where Element == String {
  fileprivate func value(after argument: String) -> String? {
    guard let index = firstIndex(of: argument) else { return nil }
    let valueIndex = self.index(after: index)
    guard indices.contains(valueIndex) else { return nil }
    return self[valueIndex]
  }
}
