import FirebaseAuth
import FirebaseCore
import GoogleSignIn
import UIKit

@MainActor
enum GooglePatientAuthenticator {
  static func signIn() async throws -> FirebaseAuth.User {
    #if E2E
      if let mockIDToken = E2ERuntime.googleIDToken {
        let credential = GoogleAuthProvider.credential(
          withIDToken: mockIDToken,
          accessToken: ""
        )
        return try await Auth.auth().signIn(with: credential).user
      }
    #endif

    guard let clientID = FirebaseApp.app()?.options.clientID else {
      throw GooglePatientAuthenticationError.missingClientID
    }
    guard let presentingViewController = presentingViewController() else {
      throw GooglePatientAuthenticationError.missingPresentingViewController
    }

    GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
    let result = try await GIDSignIn.sharedInstance.signIn(
      withPresenting: presentingViewController
    )
    guard let idToken = result.user.idToken?.tokenString else {
      throw GooglePatientAuthenticationError.missingIDToken
    }
    let credential = GoogleAuthProvider.credential(
      withIDToken: idToken,
      accessToken: result.user.accessToken.tokenString
    )
    return try await Auth.auth().signIn(with: credential).user
  }

  static func signOut() {
    GIDSignIn.sharedInstance.signOut()
  }

  private static func presentingViewController() -> UIViewController? {
    let rootViewController = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
      .first(where: \.isKeyWindow)?
      .rootViewController
    var current = rootViewController
    while let presented = current?.presentedViewController {
      current = presented
    }
    return current
  }
}

enum GooglePatientAuthenticationError: LocalizedError {
  case missingClientID
  case missingIDToken
  case missingPresentingViewController

  var errorDescription: String? {
    switch self {
    case .missingClientID:
      "Google Sign-In is not configured for this build."
    case .missingIDToken:
      "Google did not return a usable identity token."
    case .missingPresentingViewController:
      "MediNag could not present Google Sign-In. Please try again."
    }
  }
}
