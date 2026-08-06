import FirebaseAuth
import FirebaseFirestore
import Foundation
import MediNagCore

final class FirebaseSubjectRepository: MedicationEventStore, @unchecked Sendable {
  private let database: Firestore
  private let householdID: String

  init(database: Firestore = Firestore.firestore(), householdID: String) {
    self.database = database
    self.householdID = householdID
  }

  func verifySubjectMembership(userID: String) async throws {
    let membership = try await database.document(
      "households/\(householdID)/members/\(userID)"
    ).getDocument()
    guard
      membership.exists,
      membership.data()?["role"] as? String == "subject"
    else {
      throw SubjectRepositoryError.notSubjectMember
    }
  }

  func observeSchedules(
    _ handler: @escaping @Sendable (Result<[MedicationSchedule], Error>) -> Void
  ) -> ListenerRegistration {
    database.collection("households/\(householdID)/schedules")
      .order(by: "scheduledTime")
      .addSnapshotListener { snapshot, error in
        if let error {
          handler(.failure(error))
          return
        }
        let schedules: [MedicationSchedule] =
          snapshot?.documents.compactMap { document -> MedicationSchedule? in
            let data = document.data()
            guard
              let medicationName = data["medicationName"] as? String,
              let scheduledTime = data["scheduledTime"] as? String,
              let daysOfWeek = data["daysOfWeek"] as? [Int],
              let active = data["active"] as? Bool
            else {
              return nil
            }
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
    database.collection("households/\(householdID)/medicationEvents")
      .order(by: "scheduledTime")
      .addSnapshotListener { snapshot, error in
        if let error {
          handler(.failure(error))
          return
        }
        let events = snapshot?.documents.compactMap(Self.event) ?? []
        handler(.success(events))
      }
  }

  func snooze(eventID: String, at date: Date) async throws -> MedicationEvent {
    let reference = eventReference(eventID: eventID)
    let snapshot = try await reference.getDocument()
    guard var event = Self.event(snapshot) else {
      throw SubjectRepositoryError.missingEvent
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
      throw SubjectRepositoryError.missingEvent
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
      "households/\(householdID)/medicationEvents/\(eventID)"
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
    else {
      return nil
    }
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

enum SubjectRepositoryError: LocalizedError {
  case notSubjectMember
  case missingEvent

  var errorDescription: String? {
    switch self {
    case .notSubjectMember:
      "This account has not been added to the selected household as Steve."
    case .missingEvent:
      "The medication event is no longer available."
    }
  }
}
