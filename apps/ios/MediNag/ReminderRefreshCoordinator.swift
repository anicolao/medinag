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
    maximumReminderCount: Int,
    repeatIntervalMinutes: Int = 3
  ) async throws -> NotificationReconciliation {
    await notifications.setRepeatInterval(Double(repeatIntervalMinutes * 60))
    let result = try await notifications.reconcile(
      events: events,
      snoozeInterval: TimeInterval(snoozeIntervalMinutes * 60),
      maximumReminderCount: maximumReminderCount
    )
    // Network reporting must never hold the local queue or action completion.
    Task {
      do {
        try await report(result, administratorID: administratorID, patientID: patientID, timeZone: timeZone)
      } catch {
        LocalAlertJournal.record("coverage_report_deferred", details: ["error": error.localizedDescription])
      }
    }
    return result
  }

  private func report(_ result: NotificationReconciliation, administratorID: String,
                      patientID: String, timeZone: String) async throws {
    // An empty queue is healthy after every dose is complete. Otherwise the
    // planner registers future initial alerts and unanswered follow-ups.
    let ready = result.actualPendingCount == result.expectedPendingCount
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
  }
}

enum BackgroundReminderRefresh {
  static func refreshCachedQueue(reason: String) async {
    guard FirebaseBootstrap.configure(), let user = Auth.auth().currentUser else { return }
    let patientID = user.uid
    do {
      guard let cache = try DurableAlertStorage.load(PatientAlertCache.self, name: "phone-plan.json"),
        cache.patientID == user.uid else { return }
      #if E2E
        let timeline = E2ERuntime.notificationTimeline()
      #else
        let timeline = SystemNotificationTimeline()
      #endif
      let events = await MainActor.run {
        LocalResponseOutbox().applying(to: cache.events, patientID: patientID, administratorID: cache.plan.id)
      }
      let scheduler = LocalNotificationScheduler(timeline: timeline)
      let result = try await ReminderRefreshCoordinator(notifications: scheduler, healthReporter: SystemHealthReporter())
        .refresh(events: events, administratorID: cache.plan.id, patientID: user.uid,
          timeZone: TimeZone.autoupdatingCurrent.identifier,
          snoozeIntervalMinutes: cache.plan.snoozeIntervalMinutes, maximumReminderCount: Int.max,
          repeatIntervalMinutes: cache.plan.repeatIntervalMinutes)
      LocalAlertJournal.record("cached_queue_refreshed", deadline: result.scheduledThrough,
        details: ["reason": reason, "pending": String(result.actualPendingCount)])
    } catch is CancellationError {
      // A newer actual queue update owns reconciliation.
    } catch {
      LocalAlertJournal.record("cached_queue_refresh_failed", details: ["reason": reason, "error": error.localizedDescription])
      if let cache = try? DurableAlertStorage.load(PatientAlertCache.self, name: "phone-plan.json"), cache.patientID == user.uid {
        let message = error.localizedDescription
        Task {
          _ = await SystemHealthReporter().reportIncident(ClientSystemIncident(
            code: "local_queue_refresh_failed", message: "The iPhone could not restore required local alert coverage.",
            severity: "critical", context: ["reason": reason, "error": message]),
            administratorID: cache.plan.id, patientID: patientID)
        }
      }
    }
  }

  static func run() async throws {
    // Always repair from durable data before any network-dependent operation.
    await refreshCachedQueue(reason: "background_execution")
    guard FirebaseBootstrap.configure(), let user = Auth.auth().currentUser else { return }
    let patientID = user.uid
    let directory = FirebasePatientDirectory()
    guard let context = try await directory.backgroundRefreshContext(userID: user.uid) else {
      return
    }
    let timeZone = TimeZone.autoupdatingCurrent.identifier
    #if E2E
      let timeline = E2ERuntime.notificationTimeline()
    #else
      let timeline = SystemNotificationTimeline()
    #endif
    let notifications = LocalNotificationScheduler(timeline: timeline)
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
      let fetched = try await FirebaseFollowedPlanRepository(
        administratorID: context.administratorID
      ).fetchEvents()
      // Background refresh must not reinstall reminders for an offline tap.
      let cache = try? DurableAlertStorage.load(PatientAlertCache.self, name: "phone-plan.json")
      let matchingCache = cache.flatMap { $0.patientID == patientID && $0.plan.id == context.administratorID ? $0 : nil }
      let events = await MainActor.run {
        let eligible = fetched.filter { event in
          guard let start = matchingCache?.protectionStart else { return true }
          return event.scheduledTime >= start
        }
        let prepared = AlertTiming.applyingPolicy(to: eligible, previous: matchingCache?.events ?? [],
          at: timeline.now, snoozeInterval: Double(context.snoozeIntervalMinutes * 60),
          repeatInterval: Double(context.repeatIntervalMinutes * 60))
        return LocalResponseOutbox().applying(to: prepared, patientID: patientID,
          administratorID: context.administratorID)
      }
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
        maximumReminderCount: context.maximumReminderCount,
        repeatIntervalMinutes: context.repeatIntervalMinutes
      )
      try Task.checkCancellation()
      if let matchingCache {
        var plan = matchingCache.plan
        plan.snoozeIntervalMinutes = context.snoozeIntervalMinutes
        plan.repeatIntervalMinutes = context.repeatIntervalMinutes
        try DurableAlertStorage.save(PatientAlertCache(patientID: patientID, plan: plan,
          events: events, protectionStart: matchingCache.protectionStart), name: "phone-plan.json")
        await MainActor.run {
          NotificationCenter.default.post(name: .localScheduleRefreshed, object: nil)
        }
      }
    } catch {
      if error is CancellationError && !Task.isCancelled {
        // Another real queue update superseded this one; that is not a failure
        // to refresh and must not send an administrator a false alarm.
        LocalAlertJournal.record("background_refresh_superseded")
        return
      }
      await health.reportIncident(
        ClientSystemIncident(
          code: error is CancellationError
            ? "background_refresh_expired"
            : "background_refresh_failed",
          message: error is CancellationError
            ? "iOS ended reminder maintenance before it completed."
            : "Reminder maintenance did not complete.",
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
