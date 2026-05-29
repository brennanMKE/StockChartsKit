import Foundation
import StockChartsKit

/// The in-flight OAuth 2.0 PKCE exchange vended by ``CoinbaseProvider``.
///
/// Holds the PKCE verifier and the opaque `state` for the duration of the
/// redirect. On `complete(callbackURL:)` it validates `state`, extracts the
/// authorization `code`, and asks the provider to exchange it for tokens. PIN
/// completion is unsupported (Coinbase is a redirect flow).
final class CoinbaseAuthSession: AuthSession {
  let pkce: PKCE
  let state: String
  // A strong reference is safe: the provider clears its `pendingSession` once
  // the exchange completes, is cancelled, or sign-out runs, so the cycle is
  // always broken within the bounded auth flow.
  private let provider: CoinbaseProvider

  init(provider: CoinbaseProvider, pkce: PKCE, state: String) {
    self.provider = provider
    self.pkce = pkce
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
    try await provider.exchangeCode(code, verifier: pkce.verifier)
  }

  func complete(pinCode: String) async throws {
    throw BrokerageError.unsupported(method: "complete(pinCode:)")
  }

  func cancel() async {
    // Nothing to revoke before token exchange; dropping the session is enough.
  }
}
