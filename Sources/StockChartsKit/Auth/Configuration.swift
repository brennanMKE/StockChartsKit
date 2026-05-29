import Foundation

/// Developer-app credentials handed to a provider at init.
///
/// Carries only the per-provider keys registered with a brokerage's developer
/// portal (e.g. E*Trade `consumerKey`/`consumerSecret`, Coinbase `clientID`).
/// Per-user tokens are never stored here — those are read and written through
/// ``KeychainStore``.
///
/// The package never reads secrets from the environment or disk on its own: the
/// host seeds this value from the macOS Keychain at launch and passes it in.
public struct Configuration: Sendable {
  /// Opaque, provider-defined credential keys (e.g. `"consumerKey"`).
  public let secrets: [String: String]

  /// Creates a configuration from a dictionary of provider-defined secrets.
  public init(secrets: [String: String]) {
    self.secrets = secrets
  }

  /// Returns the value for a required secret key.
  ///
  /// - Parameter key: The provider-defined key to look up.
  /// - Returns: The stored secret value.
  /// - Throws: ``BrokerageError/authenticationFailed(reason:)`` if the key is
  ///   missing. The thrown reason names the key but never the value.
  public func requiredSecret(_ key: String) throws -> String {
    guard let value = secrets[key] else {
      throw BrokerageError.authenticationFailed(
        reason: "Missing required configuration secret: \(key)"
      )
    }
    return value
  }
}
