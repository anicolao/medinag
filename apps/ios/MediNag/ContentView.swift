import MediNagCore
import SwiftUI

struct ContentView: View {
  @ObservedObject var viewModel: AppViewModel

  var body: some View {
    Group {
      switch viewModel.state {
      case .starting:
        ProgressView("Preparing MediNag…")
          .accessibilityIdentifier("app-starting")

      case .signedOut:
        SubjectSignInView(viewModel: viewModel)

      case .ready:
        TodayView(viewModel: viewModel)

      case .configurationMissing:
        SetupRequiredView()

      case .failed(let message):
        FailureView(message: message) {
          viewModel.returnToSignIn()
        }
      }
    }
    .fontDesign(.rounded)
    .tint(MediNagColor.teal)
  }
}

private struct SubjectSignInView: View {
  @ObservedObject var viewModel: AppViewModel
  @State private var email = ""
  @State private var password = ""
  @State private var householdID = ""

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 28) {
          BrandHeader(
            eyebrow: "STEVE'S MEDICATION PLAN",
            title: "Sign in once",
            detail: "MediNag will stay connected to Lori's household on this iPhone."
          )

          VStack(spacing: 16) {
            LabeledField(title: "Email") {
              TextField("steve@example.com", text: $email)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
                .accessibilityIdentifier("subject-email")
            }
            LabeledField(title: "Password") {
              SecureField("Password", text: $password)
                .textContentType(.password)
                .accessibilityIdentifier("subject-password")
            }
            LabeledField(title: "Household ID") {
              TextField("Provided by Lori", text: $householdID)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("household-id")
            }
          }
          .padding(22)
          .background(.white, in: RoundedRectangle(cornerRadius: 22))
          .shadow(color: .black.opacity(0.06), radius: 24, y: 12)

          Button {
            Task {
              await viewModel.signIn(
                email: email,
                password: password,
                householdID: householdID
              )
            }
          } label: {
            HStack {
              if viewModel.isWorking {
                ProgressView().tint(.white)
              }
              Text(viewModel.isWorking ? "Connecting…" : "Connect this iPhone")
                .frame(maxWidth: .infinity)
            }
          }
          .buttonStyle(PrimaryButtonStyle())
          .disabled(viewModel.isWorking)
          .accessibilityIdentifier("subject-sign-in")

          Text(
            "The household ID is a temporary MVP pairing mechanism. It does not grant access unless Lori has already added this Firebase account as the subject."
          )
          .font(.footnote)
          .foregroundStyle(MediNagColor.muted)
        }
        .padding(24)
      }
      .background(MediNagColor.background)
      .navigationBarHidden(true)
    }
  }
}

private struct TodayView: View {
  @ObservedObject var viewModel: AppViewModel

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          HStack(alignment: .top) {
            BrandHeader(
              eyebrow: "STEVE'S DAILY PLAN",
              title: "Today",
              detail: "One clear place for every medication response."
            )
            Spacer()
            Button("Sign out") { viewModel.signOut() }
              .font(.caption.weight(.semibold))
              .accessibilityIdentifier("sign-out")
          }

          NotificationReadinessCard(viewModel: viewModel)

          if let next = viewModel.nextEvent {
            NextDoseCard(event: next, viewModel: viewModel)
          } else if let schedule = viewModel.schedules.first {
            ScheduleWaitingCard(schedule: schedule)
          } else {
            EmptyPlanCard()
          }

          if !viewModel.events.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
              Text("Today's activity")
                .font(.title3.bold())
                .foregroundStyle(MediNagColor.ink)
              ForEach(viewModel.events) { event in
                EventRow(event: event)
              }
            }
          }

          if !viewModel.actionNotice.isEmpty {
            Text(viewModel.actionNotice)
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(MediNagColor.teal)
              .padding(16)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(MediNagColor.teal.opacity(0.09), in: RoundedRectangle(cornerRadius: 16))
              .accessibilityIdentifier("action-notice")
          }
        }
        .padding(22)
      }
      .background(MediNagColor.background)
      .navigationBarHidden(true)
    }
    .accessibilityIdentifier("today-screen")
  }
}

private struct NotificationReadinessCard: View {
  @ObservedObject var viewModel: AppViewModel

  var body: some View {
    HStack(spacing: 14) {
      Image(
        systemName: viewModel.notificationReadiness == .ready
          ? "bell.badge.fill"
          : "bell.slash.fill"
      )
      .font(.title2)
      .foregroundStyle(
        viewModel.notificationReadiness == .ready
          ? MediNagColor.success
          : MediNagColor.warning)
      VStack(alignment: .leading, spacing: 3) {
        Text(
          viewModel.notificationReadiness == .ready
            ? "Reminders are ready"
            : "Allow medication reminders"
        )
        .font(.headline)
        Text(
          viewModel.notificationReadiness == .ready
            ? "This iPhone can present scheduled dose alerts."
            : "Notifications are required for the medication nag loop."
        )
        .font(.caption)
        .foregroundStyle(MediNagColor.muted)
      }
      Spacer()
      if viewModel.notificationReadiness != .ready {
        Button("Allow") {
          Task { await viewModel.requestNotifications() }
        }
        .buttonStyle(.borderedProminent)
        .disabled(viewModel.isWorking)
        .accessibilityIdentifier("allow-notifications")
      }
    }
    .padding(18)
    .background(.white, in: RoundedRectangle(cornerRadius: 18))
    .accessibilityIdentifier("notification-readiness")
  }
}

private struct NextDoseCard: View {
  let event: MedicationEvent
  @ObservedObject var viewModel: AppViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        VStack(alignment: .leading, spacing: 6) {
          Text(event.status == .snoozed ? "REMINDER SNOOZED" : "NEXT DOSE")
            .font(.caption2.bold())
            .tracking(1.4)
            .foregroundStyle(MediNagColor.teal)
          Text(event.scheduledTime.formatted(date: .omitted, time: .shortened))
            .font(.system(size: 42, weight: .bold, design: .rounded))
            .foregroundStyle(MediNagColor.ink)
        }
        Spacer()
        Image(systemName: "pills.circle.fill")
          .font(.system(size: 48))
          .foregroundStyle(MediNagColor.teal)
      }

      Text(event.medicationName)
        .font(.title2.bold())
        .foregroundStyle(MediNagColor.ink)
        .accessibilityIdentifier("next-dose-name")

      if event.snoozeCount > 0 {
        Text("Reminded \(event.snoozeCount) time\(event.snoozeCount == 1 ? "" : "s")")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(MediNagColor.warning)
          .accessibilityIdentifier("snooze-count")
      }

      VStack(spacing: 12) {
        Button("Yes, I did") {
          Task { await viewModel.respond(.yesIDid, to: event) }
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(viewModel.isWorking)
        .accessibilityIdentifier("yes-i-did")

        Button("Yes, I will") {
          Task { await viewModel.respond(.yesIWill, to: event) }
        }
        .buttonStyle(SecondaryButtonStyle())
        .disabled(viewModel.isWorking)
        .accessibilityIdentifier("yes-i-will")
      }
    }
    .padding(24)
    .background(.white, in: RoundedRectangle(cornerRadius: 24))
    .overlay {
      RoundedRectangle(cornerRadius: 24)
        .stroke(MediNagColor.teal.opacity(0.18), lineWidth: 1)
    }
    .shadow(color: .black.opacity(0.07), radius: 26, y: 12)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("next-dose-card")
  }
}

private struct ScheduleWaitingCard: View {
  let schedule: MedicationSchedule

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("NEXT SCHEDULE")
        .font(.caption2.bold())
        .tracking(1.3)
        .foregroundStyle(MediNagColor.teal)
      Text(schedule.scheduledTime)
        .font(.largeTitle.bold())
      Text(schedule.medicationName)
        .font(.headline)
      Text("Lori's schedule is synced. Today's dose event will appear here when it is generated.")
        .font(.subheadline)
        .foregroundStyle(MediNagColor.muted)
    }
    .padding(22)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.white, in: RoundedRectangle(cornerRadius: 22))
    .accessibilityIdentifier("next-schedule-card")
  }
}

private struct EventRow: View {
  let event: MedicationEvent

  var body: some View {
    HStack(spacing: 14) {
      Text(event.scheduledTime.formatted(date: .omitted, time: .shortened))
        .font(.headline.monospacedDigit())
        .frame(width: 76, alignment: .leading)
      VStack(alignment: .leading, spacing: 3) {
        Text(event.medicationName).font(.subheadline.bold())
        Text(statusText)
          .font(.caption)
          .foregroundStyle(MediNagColor.muted)
      }
      Spacer()
      Image(systemName: statusIcon)
        .foregroundStyle(statusColor)
    }
    .padding(16)
    .background(.white, in: RoundedRectangle(cornerRadius: 16))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("event-\(event.id)")
  }

  private var statusText: String {
    switch event.status {
    case .pending: "Waiting for your response"
    case .snoozed: "Snoozed ×\(event.snoozeCount)"
    case .completed: "Completed"
    }
  }

  private var statusIcon: String {
    switch event.status {
    case .pending: "clock.fill"
    case .snoozed: "bell.badge.fill"
    case .completed: "checkmark.circle.fill"
    }
  }

  private var statusColor: Color {
    event.status == .completed ? MediNagColor.success : MediNagColor.warning
  }
}

private struct EmptyPlanCard: View {
  var body: some View {
    VStack(spacing: 14) {
      Image(systemName: "calendar.badge.checkmark")
        .font(.system(size: 42))
        .foregroundStyle(MediNagColor.teal)
      Text("No doses scheduled")
        .font(.title3.bold())
      Text("Lori's active medication plan will appear here automatically.")
        .font(.subheadline)
        .foregroundStyle(MediNagColor.muted)
        .multilineTextAlignment(.center)
    }
    .padding(30)
    .frame(maxWidth: .infinity)
    .background(.white, in: RoundedRectangle(cornerRadius: 22))
    .accessibilityIdentifier("empty-plan")
  }
}

private struct SetupRequiredView: View {
  var body: some View {
    VStack(spacing: 18) {
      Image(systemName: "wrench.and.screwdriver.fill")
        .font(.system(size: 44))
        .foregroundStyle(MediNagColor.teal)
      Text("Firebase setup required").font(.title2.bold())
      Text(
        "Add GoogleService-Info.plist to MediNag/Resources, regenerate the project, and relaunch."
      )
      .multilineTextAlignment(.center)
      .foregroundStyle(MediNagColor.muted)
    }
    .padding(28)
    .background(MediNagColor.background)
    .accessibilityIdentifier("firebase-setup-required")
  }
}

private struct FailureView: View {
  let message: String
  let retry: () -> Void

  var body: some View {
    VStack(spacing: 18) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 44))
        .foregroundStyle(MediNagColor.warning)
      Text("Connection needs attention").font(.title2.bold())
      Text(message)
        .multilineTextAlignment(.center)
        .foregroundStyle(MediNagColor.muted)
      Button("Return to sign in", action: retry)
        .buttonStyle(PrimaryButtonStyle())
    }
    .padding(28)
    .background(MediNagColor.background)
    .accessibilityIdentifier("connection-failure")
  }
}

private struct BrandHeader: View {
  let eyebrow: String
  let title: String
  let detail: String

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 8) {
        Image(systemName: "capsule.portrait.fill")
        Text("MEDINAG")
      }
      .font(.caption.bold())
      .tracking(1.4)
      .foregroundStyle(MediNagColor.teal)
      Text(eyebrow)
        .font(.caption2.bold())
        .tracking(1.2)
        .foregroundStyle(MediNagColor.muted)
      Text(title)
        .font(.system(size: 36, weight: .bold, design: .rounded))
        .foregroundStyle(MediNagColor.ink)
      Text(detail)
        .font(.subheadline)
        .foregroundStyle(MediNagColor.muted)
    }
  }
}

private struct LabeledField<Field: View>: View {
  let title: String
  let field: Field

  init(title: String, @ViewBuilder field: () -> Field) {
    self.title = title
    self.field = field()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).font(.caption.bold()).foregroundStyle(MediNagColor.ink)
      field
        .padding(14)
        .background(MediNagColor.background, in: RoundedRectangle(cornerRadius: 12))
    }
  }
}

private struct PrimaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.headline)
      .foregroundStyle(.white)
      .padding(.vertical, 16)
      .padding(.horizontal, 20)
      .frame(maxWidth: .infinity)
      .background(MediNagColor.teal, in: RoundedRectangle(cornerRadius: 15))
      .opacity(configuration.isPressed ? 0.82 : 1)
  }
}

private struct SecondaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.headline)
      .foregroundStyle(MediNagColor.teal)
      .padding(.vertical, 15)
      .padding(.horizontal, 20)
      .frame(maxWidth: .infinity)
      .background(MediNagColor.teal.opacity(0.09), in: RoundedRectangle(cornerRadius: 15))
      .opacity(configuration.isPressed ? 0.75 : 1)
  }
}

private enum MediNagColor {
  static let teal = Color(red: 0.12, green: 0.43, blue: 0.43)
  static let ink = Color(red: 0.11, green: 0.24, blue: 0.26)
  static let muted = Color(red: 0.40, green: 0.50, blue: 0.51)
  static let background = Color(red: 0.95, green: 0.97, blue: 0.96)
  static let success = Color(red: 0.23, green: 0.62, blue: 0.45)
  static let warning = Color(red: 0.82, green: 0.47, blue: 0.24)
}
