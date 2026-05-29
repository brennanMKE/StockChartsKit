import Foundation

/// A user-facing step a host must resolve to finish authenticating a provider.
///
/// Each `BrokerageProvider` drives its own auth dance. When the provider needs
/// the user to do something (open a URL, paste a verifier code, complete an MFA
/// prompt), it surfaces one of these challenges. The host presents the
/// appropriate UI and then drives the matching `AuthSession` callback.
public enum AuthChallenge: Sendable {
  /// Open this URL in a browser, capture the redirect back to `callbackScheme`,
  /// then call `AuthSession.complete(callbackURL:)`.
  ///
  /// Used by OAuth 2.0 providers (Coinbase, Schwab).
  case oauthRedirect(authorizationURL: URL, callbackScheme: String)

  /// Open this URL, let the user log in and obtain a verifier PIN, then call
  /// `AuthSession.complete(pinCode:)`.
  ///
  /// Used by E*Trade's OAuth 1.0a three-legged flow.
  case pinCode(authorizationURL: URL)

  /// The user must complete a multi-factor prompt in their broker's own app.
  ///
  /// `prompt` is human-readable copy the host can display while waiting.
  case mfaPushNotification(prompt: String)

  /// Present SnapTrade's hosted connection portal at this URL.
  case hostedPortal(url: URL)
}
