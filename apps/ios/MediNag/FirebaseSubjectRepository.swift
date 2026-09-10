import FirebaseFirestore
import Foundation
import MediNagCore

struct PublishedPlan: Identifiable, Equatable {
  let id: String
  let administratorName: String
  let planName: String
  let planCode: String
  let patientUID: String?
  let snoozeIntervalMinutes: Int
  let maxReminders: Int
  let nextDoseName: String
  let nextDoseTime: String
}

final class FirebasePatientDirectory: @unchecked Sendable {
  private let database: Firestore

  init(database: Firestore = Firestore.firestore()) {
    self.database = database
  }

  func ensurePatient(userID: String, displayName: String, email: String) async throws {
    let reference = database.document("patients/\(userID)")
    let snapshot = try await reference.getDocument()
    if snapshot.exists {
      try await reference.updateData([
        "displayName": displayName,
        "email": email,
        "updatedAt": FieldValue.serverTimestamp(),
      ])
    } else {
      try await reference.setData([
        "uid": userID,
        "displayName": displayName,
        "email": email,
        "followingAdministratorUid": NSNull(),
        "createdAt": FieldValue.serverTimestamp(),
        "updatedAt": FieldValue.serverTimestamp(),
      ])
    }
  }

  func followingAdministratorID(userID: String) async throws -> String? {
    let snapshot = try await database.document("patients/\(userID)").getDocument()
    return snapshot.data()?["followingAdministratorUid"] as? String
  }

  func availablePlans(for userID: String) async throws -> [PublishedPlan] {
    let snapshot = try await database.collection("administrators")
      .whereField("published", isEqualTo: true)
      .getDocuments()
    var plans: [PublishedPlan] = []
    for document in snapshot.documents {
      let data = document.data()
      let patientUID = data["patientUid"] as? String
      guard patientUID == nil || patientUID == userID else { continue }
      let doses = try await database.collection(
        "administrators/\(document.documentID)/doses"
      )
      .order(by: "scheduledTime")
      .getDocuments()
      let firstDose = doses.documents.first(where: {
        ($0.data()["active"] as? Bool) == true
      })?.data()
      plans.append(PublishedPlan(
        id: document.documentID,
        administratorName: data["displayName"] as? String ?? "Administrator",
        planName: data["planName"] as? String ?? "Medication schedule",
        planCode: data["planCode"] as? String ?? "",
        patientUID: patientUID,
        snoozeIntervalMinutes: data["snoozeIntervalMinutes"] as? Int ?? 10,
        maxReminders: data["maxReminders"] as? Int ?? 3,
        nextDoseName: firstDose?["medicationName"] as? String ?? "No active doses",
        nextDoseTime: firstDose?["scheduledTime"] as? String ?? ""
      ))
    }
    return plans.sorted {
      $0.administratorName.localizedCaseInsensitiveCompare($1.administratorName)
        == .orderedAscending
    }
  }

  func plan(administratorID: String, userID: String) async throws -> PublishedPlan {
    guard let plan = try await availablePlans(for: userID)
      .first(where: { $0.id == administratorID })
    else {
      throw PatientRepositoryError.planUnavailable
    }
    return plan
  }

  func follow(_ plan: PublishedPlan, userID: String, displayName: String) async throws {
    let administrator = database.document("administrators/\(plan.id)")
    let patient = database.document("patients/\(userID)")
    _ = try await database.runTransaction { transaction, errorPointer in
      do {
        let administratorSnapshot = try transaction.getDocument(administrator)
        let data = administratorSnapshot.data() ?? [:]
        guard data["published"] as? Bool == true else {
          throw PatientRepositoryError.planUnavailable
        }
        let currentPatient = data["patientUid"] as? String
        guard currentPatient == nil || currentPatient == userID else {
          throw PatientRepositoryError.planAlreadyFollowed
        }
        transaction.updateData([
          "patientUid": userID,
          "patientDisplayName": displayName,
          "updatedAt": FieldValue.serverTimestamp(),
        ], forDocument: administrator)
        transaction.updateData([
          "followingAdministratorUid": plan.id,
          "updatedAt": FieldValue.serverTimestamp(),
        ], forDocument: patient)
        return nil
      } catch {
        errorPointer?.pointee = error as NSError
        return nil
      }
    }
  }

  func leave(_ plan: PublishedPlan, userID: String) async throws {
    let administrator = database.document("administrators/\(plan.id)")
    let patient = database.document("patients/\(userID)")
    _ = try await database.runTransaction { transaction, errorPointer in
      do {
        let snapshot = try transaction.getDocument(administrator)
        if snapshot.data()?["patientUid"] as? String == userID {
          transaction.updateData([
            "patientUid": NSNull(),
            "patientDisplayName": "",
            "updatedAt": FieldValue.serverTimestamp(),
          ], forDocument: administrator)
        }
        transaction.updateData([
          "followingAdministratorUid": NSNull(),
          "updatedAt": FieldValue.serverTimestamp(),
        ], forDocument: patient)
        return nil
      } catch {
        errorPointer?.pointee = error as NSError
        return nil
      }
    }
  }

  func clearInvalidFollowing(userID: String) async throws {
    try await database.document("patients/\(userID)").updateData([
      "followingAdministratorUid": NSNull(),
      "updatedAt": FieldValue.serverTimestamp(),
    ])
  }

  func observeAccess(
    administratorID: String,
    userID: String,
    _ handler: @escaping @Sendable (Result<Bool, Error>) -> Void
  ) -> ListenerRegistration {
    database.document("administrators/\(administratorID)")
      .addSnapshotListener { snapshot, error in
        if let error {
          handler(.failure(error))
          return
        }
        let data = snapshot?.data()
        let hasAccess = data?["published"] as? Bool == true
          && data?["patientUid"] as? String == userID
        // A listener installed immediately after the claim transaction may first
        // replay the cached pre-claim document. Only a server-confirmed loss of
        // access is allowed to tear down a working patient connection.
        if !hasAccess && snapshot?.metadata.isFromCache == true {
          return
        }
        handler(.success(hasAccess))
      }
  }
}

final class FirebaseFollowedPlanRepository: MedicationEventStore, @unchecked Sendable {
  private let database: Firestore
  let administratorID: String

  init(
    database: Firestore = Firestore.firestore(),
    administratorID: String
  ) {
    self.database = database
    self.administratorID = administratorID
  }

  func observeSchedules(
    _ handler: @escaping @Sendable (Result<[MedicationSchedule], Error>) -> Void
  ) -> ListenerRegistration {
    database.collection("administrators/\(administratorID)/doses")
      .order(by: "scheduledTime")
      .addSnapshotListener { snapshot, error in
        if let error {
          handler(.failure(error))
          return
        }
        let schedules: [MedicationSchedule] = snapshot?.documents.compactMap { document in
          let data = document.data()
          guard
            let medicationName = data["medicationName"] as? String,
            let scheduledTime = data["scheduledTime"] as? String,
            let daysOfWeek = data["daysOfWeek"] as? [Int],
            let active = data["active"] as? Bool
          else { return nil }
          return MedicationSchedule(
            id: document.documentID,
            medicationName: medicationName,
            scheduledTime: scheduledTime,
            daysOfWeek: daysOfWeek,
            active: active
          )
        } ?? []
        handler(.success(schedules))
      }
  }

  func observeEvents(
    _ handler: @escaping @Sendable (Result<[MedicationEvent], Error>) -> Void
  ) -> ListenerRegistration {
    database.collection("administrators/\(administratorID)/medicationEvents")
      .order(by: "scheduledTime")
      .addSnapshotListener { snapshot, error in
        if let error {
          handler(.failure(error))
          return
        }
        handler(.success(snapshot?.documents.compactMap(Self.event) ?? []))
      }
  }

  func snooze(eventID: String, at date: Date) async throws -> MedicationEvent {
    let reference = eventReference(eventID: eventID)
    let snapshot = try await reference.getDocument()
    guard var event = Self.event(snapshot) else {
      throw PatientRepositoryError.missingEvent
    }
    event.status = .snoozed
    event.snoozeCount += 1
    event.lastSnoozedAt = date
    try await reference.updateData([
      "status": MedicationEventStatus.snoozed.rawValue,
      "snoozeCount": event.snoozeCount,
      "lastSnoozedAt": Timestamp(date: date),
      "updatedAt": FieldValue.serverTimestamp(),
    ])
    return event
  }

  func complete(eventID: String, at date: Date) async throws -> MedicationEvent {
    let reference = eventReference(eventID: eventID)
    let snapshot = try await reference.getDocument()
    guard var event = Self.event(snapshot) else {
      throw PatientRepositoryError.missingEvent
    }
    event.status = .completed
    event.completedAt = date
    try await reference.updateData([
      "status": MedicationEventStatus.completed.rawValue,
      "completedAt": Timestamp(date: date),
      "updatedAt": FieldValue.serverTimestamp(),
    ])
    return event
  }

  private func eventReference(eventID: String) -> DocumentReference {
    database.document(
      "administrators/\(administratorID)/medicationEvents/\(eventID)"
    )
  }

  private static func event(_ snapshot: DocumentSnapshot) -> MedicationEvent? {
    guard let data = snapshot.data() else { return nil }
    return event(id: snapshot.documentID, data: data)
  }

  private static func event(_ snapshot: QueryDocumentSnapshot) -> MedicationEvent? {
    event(id: snapshot.documentID, data: snapshot.data())
  }

  private static func event(id: String, data: [String: Any]) -> MedicationEvent? {
    guard
      let scheduleID = data["scheduleId"] as? String,
      let medicationName = data["medicationName"] as? String,
      let scheduledTime = data["scheduledTime"] as? Timestamp,
      let statusValue = data["status"] as? String,
      let status = MedicationEventStatus(rawValue: statusValue),
      let snoozeCount = data["snoozeCount"] as? Int
    else { return nil }
    return MedicationEvent(
      id: id,
      scheduleID: scheduleID,
      medicationName: medicationName,
      scheduledTime: scheduledTime.dateValue(),
      status: status,
      snoozeCount: snoozeCount,
      lastSnoozedAt: (data["lastSnoozedAt"] as? Timestamp)?.dateValue(),
      completedAt: (data["completedAt"] as? Timestamp)?.dateValue()
    )
  }
}

enum PatientRepositoryError: LocalizedError {
  case planUnavailable
  case planAlreadyFollowed
  case missingEvent

  var errorDescription: String? {
    switch self {
    case .planUnavailable:
      "This medication schedule is no longer available."
    case .planAlreadyFollowed:
      "Another patient already follows this medication schedule."
    case .missingEvent:
      "The medication event is no longer available."
    }
  }
}
