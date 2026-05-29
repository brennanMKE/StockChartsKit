import Foundation
import Testing

@testable import StockChartsKit

@Suite("SQLiteSnapshotStore")
struct SQLiteSnapshotStoreTests {
  private let providerA = ProviderID(rawValue: "alpha")
  private let providerB = ProviderID(rawValue: "beta")

  /// Returns a unique temp-directory DB URL plus a cleanup closure.
  private func tempDBURL() -> URL {
    let dir = FileManager.default.temporaryDirectory
    return dir.appendingPathComponent("sck-snapshot-\(UUID().uuidString).sqlite")
  }

  private func removeDB(at url: URL) {
    // Remove the DB and any WAL/SHM sidecar files.
    let fm = FileManager.default
    for suffix in ["", "-wal", "-shm"] {
      try? fm.removeItem(at: URL(fileURLWithPath: url.path + suffix))
    }
  }

  private func snapshot(
    account: String,
    at offset: TimeInterval,
    total: Decimal,
    positions: [Position] = []
  ) -> PortfolioSnapshot {
    PortfolioSnapshot(
      accountID: AccountID(rawValue: account),
      timestamp: Date(timeIntervalSince1970: offset),
      totalValue: Money(total, .usd),
      positions: positions
    )
  }

  private func position(
    account: String,
    symbol: String,
    quantity: Decimal,
    marketValue: Decimal,
    at offset: TimeInterval
  ) -> Position {
    Position(
      accountID: AccountID(rawValue: account),
      symbol: Symbol(rawValue: symbol),
      assetClass: .equity,
      quantity: quantity,
      averageCost: nil,
      marketValue: Money(marketValue, .usd),
      unrealizedPL: nil,
      asOf: Date(timeIntervalSince1970: offset)
    )
  }

  @Test("migrator runs cleanly on a fresh DB and store opens")
  func freshMigration() throws {
    let url = tempDBURL()
    defer { removeDB(at: url) }
    // Opening twice must be idempotent (pending migrations re-run as no-ops).
    _ = try SQLiteSnapshotStore(url: url)
    _ = try SQLiteSnapshotStore(url: url)
  }

  @Test("record and read back a snapshot with positions round-trips")
  func roundTrip() async throws {
    let url = tempDBURL()
    defer { removeDB(at: url) }
    let store = try SQLiteSnapshotStore(url: url)

    let positions = [
      position(account: "a1", symbol: "AMD", quantity: 10, marketValue: 1000, at: 100),
      position(account: "a1", symbol: "NVDA", quantity: 2, marketValue: 500, at: 100),
    ]
    let snap = snapshot(account: "a1", at: 100, total: 1500, positions: positions)
    try await store.recordSnapshot(snap)

    let interval = DateInterval(
      start: Date(timeIntervalSince1970: 0),
      end: Date(timeIntervalSince1970: 1000)
    )
    let read = try await store.snapshots(accountID: AccountID(rawValue: "a1"), in: interval)
    #expect(read.count == 1)
    let got = try #require(read.first)
    #expect(got.accountID == AccountID(rawValue: "a1"))
    #expect(got.timestamp == Date(timeIntervalSince1970: 100))
    #expect(got.totalValue == Money(1500, .usd))
    #expect(got.positions.count == 2)
    // Positions come back ordered by symbol.
    #expect(got.positions.map { $0.symbol.rawValue } == ["AMD", "NVDA"])
    #expect(got.positions.first?.quantity == 10)
    #expect(got.positions.first?.marketValue == Money(1000, .usd))
  }

  @Test("interval filtering returns only in-range snapshots, oldest first")
  func intervalFiltering() async throws {
    let url = tempDBURL()
    defer { removeDB(at: url) }
    let store = try SQLiteSnapshotStore(url: url)

    try await store.recordSnapshot(snapshot(account: "a1", at: 100, total: 1))
    try await store.recordSnapshot(snapshot(account: "a1", at: 300, total: 2))
    try await store.recordSnapshot(snapshot(account: "a1", at: 500, total: 3))

    let interval = DateInterval(
      start: Date(timeIntervalSince1970: 200),
      end: Date(timeIntervalSince1970: 400)
    )
    let read = try await store.snapshots(accountID: AccountID(rawValue: "a1"), in: interval)
    #expect(read.count == 1)
    #expect(read.first?.timestamp == Date(timeIntervalSince1970: 300))
  }

  @Test("prune deletes snapshots and positions older than the cutoff")
  func prune() async throws {
    let url = tempDBURL()
    defer { removeDB(at: url) }
    let store = try SQLiteSnapshotStore(url: url)

    let pos = [position(account: "a1", symbol: "AMD", quantity: 1, marketValue: 100, at: 100)]
    try await store.recordSnapshot(snapshot(account: "a1", at: 100, total: 100, positions: pos))
    try await store.recordSnapshot(snapshot(account: "a1", at: 300, total: 300))

    try await store.prune(olderThan: Date(timeIntervalSince1970: 200))

    let interval = DateInterval(
      start: Date(timeIntervalSince1970: 0),
      end: Date(timeIntervalSince1970: 1000)
    )
    let read = try await store.snapshots(accountID: AccountID(rawValue: "a1"), in: interval)
    #expect(read.count == 1)
    #expect(read.first?.timestamp == Date(timeIntervalSince1970: 300))
    #expect(read.first?.positions.isEmpty == true)
  }

  @Test("Decimal precision is preserved through string serialization")
  func decimalPrecision() async throws {
    let url = tempDBURL()
    defer { removeDB(at: url) }
    let store = try SQLiteSnapshotStore(url: url)

    let precise = Decimal(string: "12345.678901234")!
    let qty = Decimal(string: "0.000123456789")!
    let pos = [
      position(account: "a1", symbol: "BTC-USD", quantity: qty, marketValue: precise, at: 100)
    ]
    try await store.recordSnapshot(
      snapshot(account: "a1", at: 100, total: precise, positions: pos)
    )

    let interval = DateInterval(
      start: Date(timeIntervalSince1970: 0),
      end: Date(timeIntervalSince1970: 1000)
    )
    let read = try await store.snapshots(accountID: AccountID(rawValue: "a1"), in: interval)
    let got = try #require(read.first)
    #expect(got.totalValue.amount == precise)
    #expect(got.positions.first?.quantity == qty)
    #expect(got.positions.first?.marketValue.amount == precise)
  }

  @Test("re-recording the same key replaces the snapshot and its positions")
  func idempotentReplace() async throws {
    let url = tempDBURL()
    defer { removeDB(at: url) }
    let store = try SQLiteSnapshotStore(url: url)

    let firstPos = [
      position(account: "a1", symbol: "AMD", quantity: 1, marketValue: 100, at: 100),
      position(account: "a1", symbol: "NVDA", quantity: 1, marketValue: 100, at: 100),
    ]
    try await store.recordSnapshot(
      snapshot(account: "a1", at: 100, total: 200, positions: firstPos)
    )
    // Replace with a single-position snapshot at the same key.
    let secondPos = [
      position(account: "a1", symbol: "AMD", quantity: 2, marketValue: 250, at: 100)
    ]
    try await store.recordSnapshot(
      snapshot(account: "a1", at: 100, total: 250, positions: secondPos)
    )

    let interval = DateInterval(
      start: Date(timeIntervalSince1970: 0),
      end: Date(timeIntervalSince1970: 1000)
    )
    let read = try await store.snapshots(accountID: AccountID(rawValue: "a1"), in: interval)
    #expect(read.count == 1)
    #expect(read.first?.totalValue == Money(250, .usd))
    #expect(read.first?.positions.count == 1)
    #expect(read.first?.positions.first?.quantity == 2)
  }

  @Test("providerID filtering uses the injected account mapping")
  func providerFiltering() async throws {
    let url = tempDBURL()
    defer { removeDB(at: url) }
    let store = try SQLiteSnapshotStore(
      url: url,
      accountProviders: [
        AccountID(rawValue: "a1"): providerA,
        AccountID(rawValue: "a2"): providerB,
      ]
    )
    try await store.recordSnapshot(snapshot(account: "a1", at: 100, total: 1))
    try await store.recordSnapshot(snapshot(account: "a2", at: 110, total: 2))
    // Unmapped account: included only when providerID is nil.
    try await store.recordSnapshot(snapshot(account: "a3", at: 120, total: 3))

    let interval = DateInterval(
      start: Date(timeIntervalSince1970: 0),
      end: Date(timeIntervalSince1970: 1000)
    )
    let alpha = try await store.snapshots(providerID: providerA, in: interval)
    #expect(alpha.count == 1)
    #expect(alpha.first?.accountID == AccountID(rawValue: "a1"))

    let all = try await store.snapshots(providerID: nil, in: interval)
    #expect(all.count == 3)
  }
}
