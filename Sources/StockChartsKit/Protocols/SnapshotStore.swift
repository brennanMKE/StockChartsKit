import Foundation

/// A local, time-ordered store of portfolio snapshots.
///
/// Providers that return only *current* state (E*Trade, Robinhood via SnapTrade,
/// Fidelity) are snapshotted periodically so the package can reconstruct a
/// historical portfolio-value series. Implementations are actors so concurrent
/// reads and writes are serialized; the default is `SQLiteSnapshotStore`.
public protocol SnapshotStore: Actor {
  /// Persists a single snapshot.
  func recordSnapshot(_ snapshot: PortfolioSnapshot) async throws

  /// Returns snapshots for one account within `interval`, oldest first.
  func snapshots(accountID: AccountID, in interval: DateInterval) async throws -> [PortfolioSnapshot]

  /// Returns snapshots within `interval` for one provider, or all providers when
  /// `providerID` is `nil`.
  func snapshots(providerID: ProviderID?, in interval: DateInterval) async throws
    -> [PortfolioSnapshot]

  /// Deletes every snapshot older than `date`.
  func prune(olderThan date: Date) async throws
}

/// One point-in-time capture of an account's total value and positions.
public struct PortfolioSnapshot: Hashable, Sendable, Codable {
  /// The account this snapshot belongs to.
  public let accountID: AccountID
  /// When the snapshot was taken.
  public let timestamp: Date
  /// The account's total value at `timestamp`.
  public let totalValue: Money
  /// The positions held at `timestamp`.
  public let positions: [Position]

  /// Creates a portfolio snapshot.
  public init(
    accountID: AccountID,
    timestamp: Date,
    totalValue: Money,
    positions: [Position]
  ) {
    self.accountID = accountID
    self.timestamp = timestamp
    self.totalValue = totalValue
    self.positions = positions
  }
}
