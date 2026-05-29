import Foundation
import GRDB
import os

/// The default ``SnapshotStore``, backed by a local SQLite database via GRDB.
///
/// Snapshots are persisted to a file-backed SQLite database so providers that
/// only return *current* state can still reconstruct a historical
/// portfolio-value series (see the default `portfolioHistory` reconstruction in
/// `PortfolioHistory.swift`). The store is an `actor`, so concurrent reads and
/// writes are serialized.
///
/// ## Decimal serialization
/// `Decimal` amounts and quantities are stored as their exact base-10 string
/// representation (the `total_value`, `quantity`, and `market_value` columns are
/// `TEXT`), never as `Double`, so full precision round-trips through the
/// database. Timestamps are stored as Unix-epoch `REAL` seconds.
///
/// ## `providerID` filtering
/// A ``PortfolioSnapshot`` and the schema carry an ``AccountID`` but no provider
/// identity, so `snapshots(providerID:in:)` cannot derive the provider from a
/// stored row alone. This store keeps an injectable `accountID -> providerID`
/// map (mirroring `InMemorySnapshotStore`). Seed it at construction, register
/// pairs with ``mapAccount(_:to:)`` / ``register(_:)``. Snapshots whose account
/// has no known provider are excluded from a non-`nil` `providerID` query and
/// included when `providerID` is `nil`.
///
/// ## Schema versioning
/// Versioning uses GRDB's `DatabaseMigrator`. `v1` is the schema in PRD §7.
/// Every future change ships as a new, ordered migration registered after the
/// existing ones — **never mutate an existing migration**, or already-migrated
/// user databases will diverge from fresh ones. Pending migrations run on
/// ``init(url:)`` so an existing user's database upgrades in place.
public actor SQLiteSnapshotStore: SnapshotStore {
  /// The underlying GRDB database queue.
  private let dbQueue: DatabaseQueue

  /// The account-to-provider mapping used by ``snapshots(providerID:in:)``.
  private var providerByAccount: [AccountID: ProviderID]

  private static let log = Logger(
    subsystem: "co.sstools.stockchartskit",
    category: "SQLiteSnapshotStore"
  )

  /// Opens (creating if necessary) the snapshot database at `url` and runs any
  /// pending migrations.
  ///
  /// - Parameters:
  ///   - url: The file URL of the SQLite database. Parent directories must
  ///     already exist.
  ///   - accountProviders: An optional seed mapping from account to provider,
  ///     used by ``snapshots(providerID:in:)``.
  /// - Throws: A GRDB error if the database cannot be opened or migrated.
  public init(url: URL, accountProviders: [AccountID: ProviderID] = [:]) throws {
    self.dbQueue = try DatabaseQueue(path: url.path)
    self.providerByAccount = accountProviders
    try Self.migrator.migrate(dbQueue)
  }

  // MARK: Migrations

  /// The ordered set of schema migrations. Append new migrations; never edit an
  /// existing one (see the type-level note on schema versioning).
  private static var migrator: DatabaseMigrator {
    var migrator = DatabaseMigrator()
    migrator.registerMigration("v1") { db in
      try db.create(table: "snapshot") { t in
        t.column("account_id", .text).notNull()
        t.column("timestamp", .double).notNull()
        t.column("total_value", .text).notNull()
        t.column("currency", .text).notNull()
        t.primaryKey(["account_id", "timestamp"])
      }
      try db.create(index: "snapshot_ts", on: "snapshot", columns: ["timestamp"])
      try db.create(table: "snapshot_position") { t in
        t.column("account_id", .text).notNull()
        t.column("timestamp", .double).notNull()
        t.column("symbol", .text).notNull()
        t.column("quantity", .text).notNull()
        t.column("market_value", .text).notNull()
        t.column("currency", .text).notNull()
        t.primaryKey(["account_id", "timestamp", "symbol"])
      }
    }
    return migrator
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

  /// Writes a snapshot and its positions in a single transaction.
  ///
  /// Re-recording the same `(accountID, timestamp)` replaces the prior snapshot
  /// row and its positions (insert-or-replace), so a re-run at an identical
  /// timestamp is idempotent.
  public func recordSnapshot(_ snapshot: PortfolioSnapshot) async throws {
    let ts = snapshot.timestamp.timeIntervalSince1970
    let accountID = snapshot.accountID.rawValue
    let totalValue = Self.string(from: snapshot.totalValue.amount)
    let currency = snapshot.totalValue.currency.rawValue
    let positions = snapshot.positions

    try await dbQueue.write { db in
      try db.execute(
        sql: """
          INSERT OR REPLACE INTO snapshot
          (account_id, timestamp, total_value, currency)
          VALUES (?, ?, ?, ?)
          """,
        arguments: [accountID, ts, totalValue, currency]
      )
      // Clear any stale position rows for this snapshot before re-inserting, so
      // a replaced snapshot does not retain positions it no longer holds.
      try db.execute(
        sql: "DELETE FROM snapshot_position WHERE account_id = ? AND timestamp = ?",
        arguments: [accountID, ts]
      )
      for position in positions {
        try db.execute(
          sql: """
            INSERT OR REPLACE INTO snapshot_position
            (account_id, timestamp, symbol, quantity, market_value, currency)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            accountID,
            ts,
            position.symbol.rawValue,
            Self.string(from: position.quantity),
            Self.string(from: position.marketValue.amount),
            position.marketValue.currency.rawValue,
          ]
        )
      }
    }
  }

  public func snapshots(
    accountID: AccountID,
    in interval: DateInterval
  ) async throws -> [PortfolioSnapshot] {
    let id = accountID.rawValue
    let start = interval.start.timeIntervalSince1970
    let end = interval.end.timeIntervalSince1970
    return try await dbQueue.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT account_id, timestamp, total_value, currency FROM snapshot
          WHERE account_id = ? AND timestamp >= ? AND timestamp <= ?
          ORDER BY timestamp ASC
          """,
        arguments: [id, start, end]
      )
      return try rows.map { try Self.snapshot(from: $0, db: db) }
    }
  }

  public func snapshots(
    providerID: ProviderID?,
    in interval: DateInterval
  ) async throws -> [PortfolioSnapshot] {
    let start = interval.start.timeIntervalSince1970
    let end = interval.end.timeIntervalSince1970
    // Resolve the set of account IDs the provider owns from the injected map.
    // A nil provider matches everything; a non-nil provider matches only mapped
    // accounts, so unmapped snapshots are excluded (mirrors InMemorySnapshotStore).
    let allowedAccounts: Set<String>?
    if let providerID {
      allowedAccounts = Set(
        providerByAccount
          .filter { $0.value == providerID }
          .map { $0.key.rawValue }
      )
    } else {
      allowedAccounts = nil
    }

    return try await dbQueue.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT account_id, timestamp, total_value, currency FROM snapshot
          WHERE timestamp >= ? AND timestamp <= ?
          ORDER BY timestamp ASC
          """,
        arguments: [start, end]
      )
      let filtered: [Row]
      if let allowedAccounts {
        filtered = rows.filter { allowedAccounts.contains($0["account_id"]) }
      } else {
        filtered = rows
      }
      return try filtered.map { try Self.snapshot(from: $0, db: db) }
    }
  }

  public func prune(olderThan date: Date) async throws {
    let cutoff = date.timeIntervalSince1970
    try await dbQueue.write { db in
      try db.execute(
        sql: "DELETE FROM snapshot_position WHERE timestamp < ?",
        arguments: [cutoff]
      )
      try db.execute(
        sql: "DELETE FROM snapshot WHERE timestamp < ?",
        arguments: [cutoff]
      )
    }
  }

  // MARK: Row hydration

  /// Reconstructs a ``PortfolioSnapshot`` (with its positions) from a snapshot row.
  private static func snapshot(from row: Row, db: Database) throws -> PortfolioSnapshot {
    let accountID = AccountID(rawValue: row["account_id"])
    let ts: Double = row["timestamp"]
    let timestamp = Date(timeIntervalSince1970: ts)
    let totalAmount = decimal(from: row["total_value"])
    let currency = CurrencyCode(rawValue: row["currency"])

    let positionRows = try Row.fetchAll(
      db,
      sql: """
        SELECT symbol, quantity, market_value, currency FROM snapshot_position
        WHERE account_id = ? AND timestamp = ?
        ORDER BY symbol ASC
        """,
      arguments: [accountID.rawValue, ts]
    )
    let positions = positionRows.map { pRow -> Position in
      Position(
        accountID: accountID,
        symbol: Symbol(rawValue: pRow["symbol"]),
        // The schema does not persist asset class; restore as `.other`. The
        // reconstruction algorithm relies only on symbol, quantity, and value.
        assetClass: .other,
        quantity: decimal(from: pRow["quantity"]),
        averageCost: nil,
        marketValue: Money(
          decimal(from: pRow["market_value"]),
          CurrencyCode(rawValue: pRow["currency"])
        ),
        unrealizedPL: nil,
        asOf: timestamp
      )
    }
    return PortfolioSnapshot(
      accountID: accountID,
      timestamp: timestamp,
      totalValue: Money(totalAmount, currency),
      positions: positions
    )
  }

  // MARK: Decimal serialization

  /// Serializes a `Decimal` to its exact base-10 string, locale-independent.
  private static func string(from value: Decimal) -> String {
    NSDecimalNumber(decimal: value).description(withLocale: Locale(identifier: "en_US_POSIX"))
  }

  /// Parses a `Decimal` from its stored string, locale-independent. A value that
  /// fails to parse is treated as zero and logged; this should not occur for
  /// data this store wrote.
  private static func decimal(from string: String) -> Decimal {
    if let value = Decimal(string: string, locale: Locale(identifier: "en_US_POSIX")) {
      return value
    }
    log.error("Failed to parse Decimal from stored value; defaulting to 0")
    return .zero
  }
}
