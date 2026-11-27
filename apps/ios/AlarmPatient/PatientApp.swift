import AlarmKit
import BackgroundTasks
import FirebaseAuth
import GoogleSignIn
import MediNagCore
import SwiftUI
import UIKit

@MainActor
final class PatientAppDelegate: NSObject, UIApplicationDelegate {
  static let refreshID = "org.boardgamescafe.medinag.alarmkit-refresh"

  func application(_ application: UIApplication,
    didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
    FirebaseBootstrap.configure()
    BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshID, using: .main) { task in
      Self.refresh(task)
    }
    Self.requestRefresh()
    return true
  }

  static func requestRefresh() {
    let request = BGAppRefreshTaskRequest(identifier: refreshID)
    request.earliestBeginDate = Date().addingTimeInterval(24 * 60 * 60)
    try? BGTaskScheduler.shared.submit(request)
  }

  private static func refresh(_ task: BGTask) {
    let completion = RefreshCompletion(task)
    let work = Task { @MainActor in
      defer { requestRefresh() }
      let cached = await PatientAlarmEngine.shared.run(.reconcile)
      PatientSession.shared.scheduleFlush()
      do {
        try Task.checkCancellation()
        if let context = cached.context, FirebaseBootstrap.configure(),
          Auth.auth().currentUser?.uid == context.patientID {
          let events = try await FirebaseFollowedPlanRepository(administratorID: context.plan.id)
            .fetchEvents(source: .server)
          try Task.checkCancellation()
          _ = await PatientAlarmEngine.shared.run(.importEvents(context, events))
        }
        completion.finish(true)
      } catch { completion.finish(false) }
    }
    task.expirationHandler = {
      work.cancel()
      Task { @MainActor in completion.finish(false) }
    }
  }

  private final class RefreshCompletion {
    private var task: BGTask?
    init(_ task: BGTask) { self.task = task }
    func finish(_ success: Bool) {
      task?.setTaskCompleted(success: success)
      task = nil
    }
  }
}

@main
struct PatientApp: App {
  @UIApplicationDelegateAdaptor(PatientAppDelegate.self) private var delegate
  @StateObject private var session = PatientSession.shared
  @Environment(\.scenePhase) private var scenePhase

  var body: some Scene {
    WindowGroup {
      PatientView(session: session)
        .task { await session.start() }
        .onOpenURL { GIDSignIn.sharedInstance.handle($0) }
        .onChange(of: scenePhase) { _, phase in
          if phase == .active {
            Task {
              await session.reload()
              _ = await PatientAlarmEngine.shared.run(.reconcile)
              await session.reload()
              session.scheduleFlush()
              PatientAppDelegate.requestRefresh()
            }
          }
        }
    }
  }
}

struct PatientView: View {
  @ObservedObject var session: PatientSession

  var body: some View {
    NavigationStack {
      Group {
        if session.local.context != nil {
          TimelineView(.periodic(from: .now, by: 1)) { timeline in
            doseView(at: timeline.date)
          }
        } else if session.starting {
          ProgressView("Opening your schedule…")
        } else if !session.signedIn {
          VStack(spacing: 24) {
            Text("MediNag").font(.largeTitle.bold())
            Button("Continue with Google") { Task { await session.signIn() } }
              .accessibilityIdentifier("google-sign-in")
            if !session.message.isEmpty { Text(session.message) }
          }
        } else {
          List(session.plans) { plan in
            Button("\(plan.administratorName) — \(plan.planName)") { Task { await session.follow(plan) } }
              .accessibilityIdentifier("follow-plan-\(plan.id)")
          }
          .navigationTitle("Choose your schedule")
        }
      }
      .padding(24)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color(red: 0.96, green: 0.98, blue: 0.98))
      .tint(.teal)
    }
    #if ALARM_RELIABILITY_TRIAL
    .safeAreaInset(edge: .top) {
      Text("Single-alarm test: only the next dose. After Stop, open MediNag to arm the next. No snooze or retries.")
        .font(.footnote).multilineTextAlignment(.center).padding(8)
        .accessibilityIdentifier("schedule-reliability-banner")
    }
    #endif
  }

  @ViewBuilder
  private func doseView(at now: Date) -> some View {
    if AlarmManager.shared.authorizationState != .authorized {
      VStack(spacing: 20) {
        Text("Allow medication alarms to continue.")
        Button("Enable alarms") { Task { await session.enableAlarms() } }
          .accessibilityIdentifier("enable-alarms")
      }
    } else if session.local.lastFailure != nil {
      VStack(spacing: 20) {
        Text("Medication alarms need attention.")
        Text("Your administrator will be notified as soon as the phone can connect.")
        Button("Try again") {
          Task {
            _ = await PatientAlarmEngine.shared.run(.reconcile)
            await session.reload()
            session.scheduleFlush()
          }
        }
      }
      .accessibilityIdentifier("alarm-attention-screen")
    } else if let next = session.local.nextDose(at: now),
      AlarmKitPolicy.canCompleteEarly(next, at: now), session.local.responseEventID == nil {
      nextDoseView(next, at: now)
    } else if let due = session.local.latestDue(at: now),
      session.local.responseEventID == due.id
        || AlertTiming.reminder(for: due, snoozeInterval: snoozeSeconds) <= now {
      VStack(spacing: 24) {
        responseButton("Yes, I did", response: .yesIDid, event: due)
        #if !ALARM_RELIABILITY_TRIAL
        responseButton("Yes, I will", response: .yesIWill, event: due)
        #endif
      }
      .buttonStyle(.bordered)
      .controlSize(.large)
      .disabled(session.busy)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("medication-response-screen")
    } else if let next = session.local.nextDose(at: now) {
      nextDoseView(next, at: now)
    } else {
      Text("No upcoming dose").accessibilityIdentifier("no-upcoming-dose")
    }
  }

  private func nextDoseView(_ next: MedicationEvent, at now: Date) -> some View {
    VStack(spacing: 24) {
      Text(next.medicationName).font(.title2)
      Text(next.scheduledTime, format: .dateTime.month().day().hour().minute())
        .font(.title.monospacedDigit()).accessibilityIdentifier("next-dose-time")
      if AlarmKitPolicy.canCompleteEarly(next, at: now) {
        responseButton("Yes, I did", response: .yesIDid, event: next)
          .buttonStyle(.bordered).controlSize(.large).disabled(session.busy)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("next-dose-screen")
  }

  private var snoozeSeconds: TimeInterval { Double((session.local.context?.plan.snoozeIntervalMinutes ?? 10) * 60) }

  private func responseButton(_ text: String, response: DoseResponse, event: MedicationEvent) -> some View {
    Button(text) { Task { await session.respond(response, eventID: event.id) } }
      .accessibilityIdentifier(response == .yesIDid ? "response-yes-i-did" : "response-yes-i-will")
  }
}
