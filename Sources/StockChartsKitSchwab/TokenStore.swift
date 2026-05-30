import Foundation
import StockChartsKit

/// A minimal credential store the Schwab provider reads and writes tokens
/// through.
///
/// The package's ``KeychainStore`` is the production implementation (see the
/// conformance below). Tests inject an in-memory implementation so the read and
/// auth flows can run offline without touching the macOS Keychain (which is
/// unavailable under `swift test`). Only this narrow surface is needed, so the
/// provider never depends on the concrete `KeychainStore` type directly.
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
