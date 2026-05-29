import CryptoKit
import Foundation

/// A PKCE (RFC 7636) code verifier/challenge pair for OAuth 2.0.
///
/// The verifier is a high-entropy random string; the challenge is the
/// base64url-encoded SHA-256 of the verifier's ASCII bytes. The authorization
/// request sends the challenge with `code_challenge_method=S256`; the token
/// exchange sends the verifier, proving the same client that started the flow is
/// finishing it — so no client secret is required.
///
/// SHA-256 uses the system `CryptoKit` framework, so this target needs no extra
/// package dependency. (The `swift-crypto` `Crypto` module would be the
/// alternative; CryptoKit is preferred here to keep the dependency graph small.)
struct PKCE: Sendable {
  /// The random code verifier, sent at token exchange.
  let verifier: String
  /// The derived code challenge, sent in the authorization request.
  let challenge: String

  /// Generates a fresh verifier (96 random bytes → 128 base64url characters,
  /// within the RFC's 43–128 range) and derives its challenge.
  init() {
    var bytes = [UInt8](repeating: 0, count: 96)
    for index in bytes.indices {
      bytes[index] = UInt8.random(in: .min ... .max)
    }
    let verifier = Data(bytes).base64URLEncodedString()
    self.verifier = verifier
    self.challenge = Self.challenge(forVerifier: verifier)
  }

  /// Derives the S256 code challenge for a known verifier.
  ///
  /// Exposed so tests can assert `challenge == base64url(SHA256(verifier))`.
  static func challenge(forVerifier verifier: String) -> String {
    let digest = SHA256.hash(data: Data(verifier.utf8))
    return Data(digest).base64URLEncodedString()
  }
}

extension Data {
  /// Returns the base64url encoding (RFC 4648 §5) without padding: `+`→`-`,
  /// `/`→`_`, and trailing `=` removed.
  func base64URLEncodedString() -> String {
    base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}
