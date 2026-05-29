import Foundation

/// An in-flight authentication exchange owned by a `BrokerageProvider`.
///
/// The provider vends an `AuthSession` from `authenticate()`. The host drives it
/// to completion by calling the callback that matches the `AuthChallenge` it was
/// asked to resolve: `complete(callbackURL:)` for an OAuth redirect, or
/// `complete(pinCode:)` for a pasted verifier. If the user abandons the flow the
/// host calls `cancel()`.
///
/// Sessions are reference types because they hold mutable, provider-internal
/// exchange state (request tokens, PKCE verifiers); they are `Sendable` so they
/// can cross actor boundaries between the host and the provider.
public protocol AuthSession: AnyObject, Sendable {
  /// Finish an `oauthRedirect` challenge with the captured callback URL.
  func complete(callbackURL: URL) async throws

  /// Finish a `pinCode` challenge with the verifier the user pasted.
  func complete(pinCode: String) async throws

  /// Abandon the in-flight exchange and release any pending state.
  func cancel() async
}
