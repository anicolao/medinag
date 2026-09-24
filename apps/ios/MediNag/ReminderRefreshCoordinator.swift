import FirebaseAuth
import Foundation
import MediNagCore
import UserNotifications

final class ReminderRefreshCoordinator: @unchecked Sendable {
  private let notifications: LocalNotificationScheduler
  private let healthReporter: SystemHealthReporter

  init(
    notifications: LocalNotificationScheduler,
    healthReporter: SystemHealthReporter
  ) {
    self.notifications = notifications
    self.healthReporter = healthReporter
  }

  func refresh(
    events: [MedicationEvent],
    administratorID: String,
    patientID: String,
    timeZone: String,
    snoozeIntervalMinutes: Int,
    maximumReminderCount: Int
  ) async throws -> NotificationReconciliation {
    let result = try await notifications.reconcile(
      events: events,
      snoozeInterval: TimeInterval(snoozeIntervalMinutes * 60),
      maximumReminderCount: maximumReminderCount
    )
    let ready = result.expectedPendingCount > 0
      && result.actualPendingCount == result.expectedPendingCount
    if let scheduledThrough = result.scheduledThrough {
      try await healthReporter.reportCoverage(
        administratorID: administratorID,
        patientID: patientID,
        timeZone: timeZone,
        scheduledThrough: scheduledThrough,
        expectedPendingCount: result.expectedPendingCount,
        actualPendingCount: result.actualPendingCount,
        ready: ready
      )
    }
    if !result.missedEventIDs.isEmpty {
      await healthReporter.reportIncident(
        ClientSystemIncident(
          code: "medication_occurrence_missed",
          message: "A medication occurrence passed before the patient iPhone registered it.",
          severity: "critical",
          context: ["eventCount": String(result.missedEventIDs.count)]
        ),
        administratorID: administratorID,
        patientID: patientID
      )
    }
    await healthReporter.flushOutbox(
      administratorID: administratorID,
      patientID: patientID
    )
    return result
  }
}

enum BackgroundReminderRefresh {
  static func run() async throws {
    guard FirebaseBootstrap.configure(), let user = Auth.auth().currentUser else { return }
    let directory = FirebasePatientDirectory()
    guard let context = try await directory.backgroundRefreshContext(userID: user.uid) else {
      return
    }
    let timeZone = TimeZone.autoupdatingCurrent.identifier
    let notifications = LocalNotificationScheduler()
    let health = SystemHealthReporter()
    do {
      try Task.checkCancellation()
      try await directory.updateTimeZone(userID: user.uid, timeZone: timeZone)
      let authorization = await notifications.authorizationStatus()
      guard [.authorized, .provisional, .ephemeral].contains(authorization) else {
        await health.reportIncident(
          ClientSystemIncident(
            code: "notification_authorization_denied",
            message: "The patient iPhone has disabled medication notifications.",
            severity: "critical",
            context: ["refresh": "background"]
          ),
          administratorID: context.administratorID,
          patientID: context.patientID
        )
        return
      }
      let events = try await FirebaseFollowedPlanRepository(
        administratorID: context.administratorID
      ).fetchEvents()
      try Task.checkCancellation()
      _ = try await ReminderRefreshCoordinator(
        notifications: notifications,
        healthReporter: health
      ).refresh(
        events: events,
        administratorID: context.administratorID,
        patientID: context.patientID,
        timeZone: timeZone,
        snoozeIntervalMinutes: context.snoozeIntervalMinutes,
        maximumReminderCount: context.maximumReminderCount
      )
    } catch {
      await health.reportIncident(
        ClientSystemIncident(
          code: error is CancellationError
            ? "background_refresh_expired"
            : "background_refresh_failed",
          message: error is CancellationError
            ? "iOS ended the daily reminder refresh before it completed."
            : "The daily reminder refresh did not complete.",
          severity: "critical",
          context: ["error": error.localizedDescription]
        ),
        administratorID: context.administratorID,
        patientID: context.patientID
      )
      throw error
    }
  }
}
