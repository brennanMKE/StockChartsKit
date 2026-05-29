import Foundation
import StockChartsKit

/// A minimal credential store the E*Trade provider reads and writes its OAuth
/// 1.0a access-token pair through.
///
/// The package's ``KeychainStore`` is the production implementation (see the
/// conformance below). Tests inject an in-memory implementation so the read and
/// auth flows can run offline without touching the macOS Keychain (which is
/// unavailable under `swift test`). Only this narrow surface is needed, so the
/// provider never depends on the concrete `KeychainStore` type directly.
///
/// This mirrors the same `TokenStore` abstraction the Coinbase provider uses;
/// each provider target declares its own copy because the targets are
/// independent and do not depend on one another.
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
