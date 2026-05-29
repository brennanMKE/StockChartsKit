import Foundation
import Security
import os

/// A Keychain-backed store for per-user provider credentials.
///
/// Wraps the Security framework (`SecItemAdd` / `SecItemCopyMatching` /
/// `SecItemUpdate` / `SecItemDelete`) directly — there is no third-party
/// dependency. Each credential is stored as a single generic-password item whose
/// account is a caller-supplied key (typically `"\(providerID).\(connectionID)"`)
/// and whose `kSecAttrService` is the `service` string passed at init (usually
/// the app's bundle identifier).
///
/// Secret values are never logged at any level. Only operation outcomes and
/// `OSStatus` codes are recorded.
public actor KeychainStore {
  private let service: String
  private let log = Logger(
    subsystem: "co.sstools.stockchartskit",
    category: "KeychainStore"
  )

  /// Creates a store scoped to a Keychain service identifier.
  ///
  /// - Parameter service: The `kSecAttrService` value for every item, typically
  ///   the host app's bundle identifier.
  public init(service: String) {
    self.service = service
  }

  /// Returns the stored secret for `key`.
  ///
  /// - Parameter key: The item account, e.g. `"etrade.conn-1"`.
  /// - Returns: The stored UTF-8 secret value.
  /// - Throws: ``BrokerageError/notAuthenticated`` if no item exists, or
  ///   ``BrokerageError/providerError(providerID:statusCode:message:)`` on any
  ///   other Keychain failure.
  public func secret(_ key: String) throws -> String {
    var query = baseQuery(for: key)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    switch status {
    case errSecSuccess:
      guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
        log.error("Keychain item for key was not valid UTF-8 data")
        throw KeychainStore.failure(status: nil, op: "read")
      }
      return value
    case errSecItemNotFound:
      throw BrokerageError.notAuthenticated
    default:
      log.error("Keychain read failed with status \(status, privacy: .public)")
      throw KeychainStore.failure(status: status, op: "read")
    }
  }

  /// Stores or replaces the secret for `key`.
  ///
  /// Adds a new generic-password item, or updates the existing one in place.
  ///
  /// - Parameters:
  ///   - value: The secret to store. Never logged.
  ///   - key: The item account, e.g. `"etrade.conn-1"`.
  /// - Throws: ``BrokerageError/providerError(providerID:statusCode:message:)``
  ///   on any Keychain failure.
  public func set(_ value: String, for key: String) throws {
    let data = Data(value.utf8)
    let update = [kSecValueData as String: data]
    let updateStatus = SecItemUpdate(baseQuery(for: key) as CFDictionary, update as CFDictionary)
    switch updateStatus {
    case errSecSuccess:
      return
    case errSecItemNotFound:
      var add = baseQuery(for: key)
      add[kSecValueData as String] = data
      let addStatus = SecItemAdd(add as CFDictionary, nil)
      guard addStatus == errSecSuccess else {
        log.error("Keychain add failed with status \(addStatus, privacy: .public)")
        throw KeychainStore.failure(status: addStatus, op: "add")
      }
    default:
      log.error("Keychain update failed with status \(updateStatus, privacy: .public)")
      throw KeychainStore.failure(status: updateStatus, op: "update")
    }
  }

  /// Removes the secret for `key`, if present.
  ///
  /// A missing item is treated as success.
  ///
  /// - Parameter key: The item account to delete.
  /// - Throws: ``BrokerageError/providerError(providerID:statusCode:message:)``
  ///   on any Keychain failure other than "not found".
  public func delete(_ key: String) throws {
    let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
    switch status {
    case errSecSuccess, errSecItemNotFound:
      return
    default:
      log.error("Keychain delete failed with status \(status, privacy: .public)")
      throw KeychainStore.failure(status: status, op: "delete")
    }
  }

  private func baseQuery(for key: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key,
    ]
  }

  /// Maps a Keychain `OSStatus` to a `BrokerageError`. The status code, never a
  /// secret value, is included in the message.
  private static func failure(status: OSStatus?, op: String) -> BrokerageError {
    let code: String
    if let status {
      code = "\(status)"
    } else {
      code = "invalid item data"
    }
    return BrokerageError.providerError(
      providerID: ProviderID(rawValue: "keychain"),
      statusCode: status.map(Int.init),
      message: "Keychain \(op) failed (\(code))"
    )
  }
}
