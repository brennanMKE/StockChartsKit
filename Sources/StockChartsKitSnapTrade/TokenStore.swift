import Foundation
import StockChartsKit

/// A minimal credential store the SnapTrade integration reads and writes the
/// per-user `userId`/`userSecret` through.
///
/// The package's ``KeychainStore`` is the production implementation (see the
/// conformance below). Tests inject an in-memory implementation so the read,
/// registration, and login flows can run offline without touching the macOS
/// Keychain (which is unavailable under `swift test`). Only this narrow surface
/// is needed, so the integration never depends on the concrete `KeychainStore`
/// type directly.
///
/// Stored values are never logged at any level.
public protocol TokenStore: Sendable {
  /// Returns the stored secret for `key`.
  ///
  /// - Throws: ``BrokerageError/notAuthenticated`` if no item exists.
  func secret(_ key: String) async throws -> String

  /// Stores or replaces the secret for `key`.
  func set(_ value: String, for key: String) async throws

  /// Removes the secret for `key`, if present.
  func delete(_ key: String) async throws
}

/// `KeychainStore` is the production ``TokenStore``.
extension KeychainStore: TokenStore {}

/// The per-user SnapTrade credentials issued by `registerUser`.
///
/// `userId` is the host-chosen end-user identifier; `userSecret` is SnapTrade's
/// opaque per-user secret. Both are required on every signed request as query
/// parameters and are persisted via the ``TokenStore``. Neither is ever logged.
public struct SnapTradeUserCredentials: Sendable, Codable, Equatable {
  /// The end-user identifier registered with SnapTrade.
  public let userId: String
  /// SnapTrade's opaque per-user secret. Never logged.
  public let userSecret: String

  /// Creates a credentials pair.
  public init(userId: String, userSecret: String) {
    self.userId = userId
    self.userSecret = userSecret
  }
}

/// The Keychain item key under which the SnapTrade user credentials are stored.
let snapTradeUserCredentialsKey = "snaptrade.user"

extension TokenStore {
  /// Loads and decodes the stored ``SnapTradeUserCredentials``.
  ///
  /// - Throws: ``BrokerageError/notAuthenticated`` if no credentials are stored.
  func loadUserCredentials() async throws -> SnapTradeUserCredentials {
    let json = try await secret(snapTradeUserCredentialsKey)
    guard let data = json.data(using: .utf8) else {
      throw BrokerageError.notAuthenticated
    }
    do {
      return try JSONDecoder().decode(SnapTradeUserCredentials.self, from: data)
    } catch {
      throw BrokerageError.notAuthenticated
    }
  }

  /// Encodes and stores `credentials`.
  func storeUserCredentials(_ credentials: SnapTradeUserCredentials) async throws {
    let data = try JSONEncoder().encode(credentials)
    guard let json = String(data: data, encoding: .utf8) else {
      throw BrokerageError.authenticationFailed(reason: "Could not encode SnapTrade credentials")
    }
    try await set(json, for: snapTradeUserCredentialsKey)
  }
}
