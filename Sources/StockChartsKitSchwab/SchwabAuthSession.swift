import Foundation
import StockChartsKit

/// The in-flight OAuth 2.0 authorization-code exchange vended by
/// ``SchwabProvider``.
///
/// Holds the opaque `state` for the duration of the redirect. On
/// `complete(callbackURL:)` it validates `state`, extracts the authorization
/// `code`, and asks the provider to exchange it for tokens (the exchange uses
/// HTTP Basic client authentication). PIN completion is unsupported (Schwab is
/// a redirect flow).
final class SchwabAuthSession: AuthSession {
  let state: String
  // A strong reference is safe: the provider clears its `pendingSession` once
  // the exchange completes, is cancelled, or sign-out runs, so the cycle is
  // always broken within the bounded auth flow.
  private let provider: SchwabProvider

  init(provider: SchwabProvider, state: String) {
    self.provider = provider
    self.state = state
  }

  func complete(callbackURL: URL) async throws {
    let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
    let items = components?.queryItems ?? []

    if let error = items.first(where: { $0.name == "error" })?.value {
      throw BrokerageError.authenticationFailed(reason: "Authorization error: \(error)")
    }
    let returnedState = items.first(where: { $0.name == "state" })?.value
    guard returnedState == state else {
      // A mismatched state is a possible CSRF; do not log either value.
      throw BrokerageError.authenticationFailed(reason: "OAuth state mismatch")
    }
    guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
      throw BrokerageError.authenticationFailed(reason: "Missing authorization code")
    }
    try await provider.exchangeCode(code)
  }

  func complete(pinCode: String) async throws {
    throw BrokerageError.unsupported(method: "complete(pinCode:)")
  }

  func cancel() async {
    await provider.clearPendingSession()
  }
}
