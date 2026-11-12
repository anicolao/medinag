import FirebaseAuth
import Foundation
import MediNagCore
import UserNotifications

/// Handles a real local notification action without a server read or foreground UI.
@MainActor
enum PhoneNotificationResponse {
  static func handle(_ notification: UNNotificationResponse) async -> Bool {
    let action = notification.actionIdentifier
    guard let response: DoseResponse = action == MediNagNotification.yesIDid ? .yesIDid
      : action == MediNagNotification.yesIWill ? .yesIWill : nil else { return false }
    var reportingContext: PatientAlertCache?
    var didSave = false
    defer {
      if didSave { NotificationCenter.default.post(name: .localDoseResponseSaved, object: nil) }
    }
    do {
      guard let patientID = Auth.auth().currentUser?.uid,
        let cache = try DurableAlertStorage.load(PatientAlertCache.self, name: "phone-plan.json"),
        cache.patientID == patientID,
        let data = notification.notification.request.content.userInfo[MediNagNotification.eventData] as? Data
      else { return false }
      reportingContext = cache
      let presented = try JSONDecoder().decode(MedicationEvent.self, from: data)
      let outbox = LocalResponseOutbox()
      let events = outbox.applying(to: cache.events, patientID: patientID, administratorID: cache.plan.id)
      #if E2E
        let timeline = E2ERuntime.notificationTimeline()
      #else
        let timeline = SystemNotificationTimeline()
      #endif
      let tap = timeline.now
      guard let current = events.first(where: { $0.id == presented.id }),
        (current.hasSameResponseVersion(as: presented) || response == .yesIDid && current.hasSameOccurrence(as: presented)),
        AlertTiming.canComplete(current, among: events, at: tap,
          snoozeInterval: Double(cache.plan.snoozeIntervalMinutes * 60)),
        response == .yesIDid || current.scheduledTime <= tap else {
        LocalAlertJournal.record("stale_notification_action_ignored", eventID: presented.id)
        return true
      }
      let recorded = LocalDoseResponse(patientID: patientID, administratorID: cache.plan.id,
        event: current, response: response, respondedAt: tap,
        snoozeInterval: Double(cache.plan.snoozeIntervalMinutes * 60))
      try outbox.append(recorded)
      didSave = true
      let updated = outbox.applying(to: events, patientID: patientID, administratorID: cache.plan.id)
      try DurableAlertStorage.save(PatientAlertCache(patientID: patientID, plan: cache.plan,
        events: updated, protectionStart: cache.protectionStart),
        name: "phone-plan.json")
      let scheduler = LocalNotificationScheduler(timeline: timeline)
      await scheduler.setRepeatInterval(Double(cache.plan.repeatIntervalMinutes * 60))
      _ = try await scheduler.reconcile(events: updated,
        snoozeInterval: Double(cache.plan.snoozeIntervalMinutes * 60), maximumReminderCount: Int.max)
      LocalAlertJournal.record("response_locally_reconciled", eventID: current.id,
        details: ["source": "notification_action"])
      return true
    } catch {
      LocalAlertJournal.record("background_response_failed", details: ["error": error.localizedDescription])
      if let cache = reportingContext {
        let message = error.localizedDescription
        Task {
          _ = await SystemHealthReporter().reportIncident(
            ClientSystemIncident(code: "background_response_failed",
              message: "The iPhone could not save a response or update local medication notifications.",
              severity: "critical", context: ["error": message]),
            administratorID: cache.plan.id, patientID: cache.patientID)
        }
      }
      return didSave
    }
  }
}

extension Notification.Name {
  static let localDoseResponseSaved = Notification.Name("medinag.local-response-saved")
  static let localScheduleRefreshed = Notification.Name("medinag.local-schedule-refreshed")
}
