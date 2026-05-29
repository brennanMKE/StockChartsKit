import Foundation
import StockChartsKit

/// An in-memory ``SnapshotStore`` for unit tests, backed by a simple array.
///
/// ## `providerID` filtering
/// A ``PortfolioSnapshot`` carries an ``AccountID`` but no provider identity, so
/// `snapshots(providerID:in:)` cannot derive the provider from a snapshot alone.
/// This store keeps an injectable `accountID -> providerID` map. Seed it at
/// construction, register pairs with ``mapAccount(_:to:)``, or pass an
/// `Account` to ``recordSnapshot(_:)`` via ``recordSnapshot(_:account:)`` to
/// learn the mapping automatically. Snapshots whose account has no known
/// provider are excluded from a non-`nil` `providerID` query (and, naturally,
/// included when `providerID` is `nil`).
public actor InMemorySnapshotStore: SnapshotStore {
  /// All recorded snapshots, kept sorted oldest-first by timestamp.
  private var storage: [PortfolioSnapshot] = []

  /// The account-to-provider mapping used by ``snapshots(providerID:in:)``.
  private var providerByAccount: [AccountID: ProviderID]

  /// Creates an empty store.
  ///
  /// - Parameter accountProviders: An optional seed mapping from account to
  ///   provider, used by ``snapshots(providerID:in:)``.
  public init(accountProviders: [AccountID: ProviderID] = [:]) {
    self.providerByAccount = accountProviders
  }

  // MARK: Mapping management

  /// Registers (or overwrites) the provider that owns `accountID`.
  public func mapAccount(_ accountID: AccountID, to providerID: ProviderID) {
    providerByAccount[accountID] = providerID
  }

  /// Registers the provider mapping for an account from its ``Account`` value.
  public func register(_ account: Account) {
    providerByAccount[account.id] = account.providerID
  }

  // MARK: SnapshotStore

  public func recordSnapshot(_ snapshot: PortfolioSnapshot) async throws {
    insertSorted(snapshot)
  }

  /// Records a snapshot and learns its account's provider mapping from `account`.
  ///
  /// A convenience for tests that want `snapshots(providerID:in:)` to work
  /// without seeding the mapping separately.
  public func recordSnapshot(
    _ snapshot: PortfolioSnapshot,
    account: Account
  ) async throws {
    providerByAccount[account.id] = account.providerID
    insertSorted(snapshot)
  }

  public func snapshots(
    accountID: AccountID,
    in interval: DateInterval
  ) async throws -> [PortfolioSnapshot] {
    storage.filter {
      $0.accountID == accountID && interval.contains($0.timestamp)
    }
  }

  public func snapshots(
    providerID: ProviderID?,
    in interval: DateInterval
  ) async throws -> [PortfolioSnapshot] {
    storage.filter { snapshot in
      guard interval.contains(snapshot.timestamp) else { return false }
      guard let providerID else { return true }
      return providerByAccount[snapshot.accountID] == providerID
    }
  }

  public func prune(olderThan date: Date) async throws {
    storage.removeAll { $0.timestamp < date }
  }

  // MARK: Helpers

  /// Inserts a snapshot while keeping ``storage`` sorted oldest-first.
  private func insertSorted(_ snapshot: PortfolioSnapshot) {
    let index = storage.firstIndex { $0.timestamp > snapshot.timestamp } ?? storage.endIndex
    storage.insert(snapshot, at: index)
  }
}
