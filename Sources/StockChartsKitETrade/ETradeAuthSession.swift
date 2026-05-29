import Foundation
import StockChartsKit

/// The in-flight OAuth 1.0a three-legged exchange vended by ``ETradeProvider``.
///
/// Created once the request token has been obtained, it holds the request
/// token/secret until the user pastes the verifier PIN. On
/// `complete(pinCode:)` it asks the provider to exchange the request token plus
/// verifier for an access token. The redirect-style `complete(callbackURL:)` is
/// unsupported (E*Trade is a PIN flow).
final class ETradeAuthSession: AuthSession {
  /// The request `oauth_token` from the request-token leg.
  let requestToken: String
  /// The request token secret, needed to sign the access-token exchange.
  let requestTokenSecret: String
  // A strong reference is safe: the provider clears its `pendingSession` once
  // the exchange completes, is cancelled, or sign-out runs, so the cycle is
  // always broken within the bounded auth flow.
  private let provider: ETradeProvider

  init(provider: ETradeProvider, requestToken: String, requestTokenSecret: String) {
    self.provider = provider
    self.requestToken = requestToken
    self.requestTokenSecret = requestTokenSecret
  }

  func complete(callbackURL: URL) async throws {
    throw BrokerageError.unsupported(method: "complete(callbackURL:)")
  }

  func complete(pinCode: String) async throws {
    let verifier = pinCode.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !verifier.isEmpty else {
      throw BrokerageError.authenticationFailed(reason: "Empty verifier PIN")
    }
    try await provider.exchangeAccessToken(
      requestToken: requestToken,
      requestTokenSecret: requestTokenSecret,
      verifier: verifier
    )
  }

  func cancel() async {
    await provider.clearPendingSession()
  }
}
