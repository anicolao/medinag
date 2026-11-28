import Foundation
import UserNotifications

enum LocalNotificationActions {
  static let category = "MEDINAG_DOSE_RESPONSE"
  static let did = "MEDINAG_YES_I_DID"
  static let will = "MEDINAG_YES_I_WILL"
  static var mode: String {
    #if MEDINAG_CRITICAL_ALERTS
    "critical"
    #else
    "ordinary-pending-entitlement"
    #endif
  }
  static func register() {
    UNUserNotificationCenter.current().setNotificationCategories([
      UNNotificationCategory(identifier: category, actions: [
        UNNotificationAction(identifier: did, title: "Yes, I did", options: []),
        UNNotificationAction(identifier: will, title: "Yes, I will", options: []),
      ], intentIdentifiers: [], options: [.customDismissAction]),
    ])
  }
}

struct LocalNotificationTap: Sendable {
  let id: String
  let action: String
  let eventID: String
  let patientID: String
  let administratorID: String
  let scheduledTime: Double
  let snoozeCount: Int
  let expectedAt: Double
}

/// Use explicit completion-handler delegates, not UIKit's async bridge (which
/// previously crashed on notification taps). No network await before completion.
extension PatientAppDelegate: UNUserNotificationCenterDelegate {
  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    let id = notification.request.identifier
    let eventID = notification.request.content.userInfo["eventID"] as? String ?? ""
    let date = notification.date
    completionHandler([.banner, .list, .sound])
    Task { @MainActor in
      _ = await PatientAlarmEngine.shared.run(.observed(id, eventID, date))
      await PatientSession.shared.reload()
      PatientSession.shared.scheduleFlush()
    }
  }
  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void) {
    let content = response.notification.request.content
    let id = response.notification.request.identifier, action = response.actionIdentifier
    let eventID = content.userInfo["eventID"] as? String ?? ""
    let patientID = content.userInfo["patientID"] as? String ?? ""
    let administratorID = content.userInfo["administratorID"] as? String ?? ""
    let tap = LocalNotificationTap(id: id, action: action, eventID: eventID,
      patientID: patientID, administratorID: administratorID,
      scheduledTime: content.userInfo["scheduledTime"] as? Double ?? -1,
      snoozeCount: content.userInfo["snoozeCount"] as? Int ?? -1,
      expectedAt: content.userInfo["deadline"] as? Double ?? -1)
    let completion = LocalNotificationCompletion(finish: completionHandler)
    Task { @MainActor in
      defer { completion.finish() }
      // The engine validates the durable account/schedule/occurrence. Saving a
      // local tap must not depend on Firebase Auth/keychain restoration or a
      // network opportunity. The existing outbox uploader requires real Auth.
      _ = await PatientAlarmEngine.shared.run(.notificationAction(tap))
      await PatientSession.shared.reload()
      PatientSession.shared.scheduleFlush()
    }
  }
}
private struct LocalNotificationCompletion: @unchecked Sendable { let finish: () -> Void }

extension Notification.Name {
  static let patientAlarmChanged = Notification.Name("medinag.patient-alarm-changed")
}
