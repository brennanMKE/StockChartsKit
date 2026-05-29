import Foundation
import Testing

@testable import StockChartsKit
import StockChartsKitTesting

/// A minimal ``BrokerageProvider`` that deliberately does **not** override
/// `portfolioHistory(accountID:range:)`, so calling it exercises the default
/// protocol-extension reconstruction (issue 0010) rather than a mock override.
///
/// `MockBrokerageProvider` provides a settable `portfolioHistory` override that
/// would shadow the extension, so it cannot be used to test the extension
/// itself.
private actor ExtensionTestProvider: BrokerageProvider {
  nonisolated let id: ProviderID
  nonisolated let displayName: String
  nonisolated let capabilities: Capabilities
  nonisolated let snapshotStore: (any SnapshotStore)?
  nonisolated let marketData: (any MarketDataProvider)?

  init(
    id: ProviderID = ProviderID(rawValue: "ext-test"),
    snapshotStore: (any SnapshotStore)? = nil,
    marketData: (any MarketDataProvider)? = nil
  ) {
    self.id = id
    self.displayName = id.rawValue
    self.capabilities = [.positions, .balances]
    self.snapshotStore = snapshotStore
    self.marketData = marketData
  }

  func authenticationStatus() async -> AuthenticationStatus { .error(.notAuthenticated) }
  func authenticate() async throws -> AuthSession {
    throw BrokerageError.unsupported(method: "authenticate")
  }
  func signOut() async throws {}
  func listAccounts() async throws -> [Account] { [] }
  func positions(for accountID: AccountID) async throws -> [Position] { [] }
  func balance(for accountID: AccountID) async throws -> Balance {
    throw BrokerageError.unsupported(method: "balance")
  }
  func quote(for symbol: Symbol) async throws -> Quote {
    throw BrokerageError.unsupported(method: "quote")
  }
  func priceHistory(symbol: Symbol, range: TimeRange) async throws -> PerformanceSeries {
    throw BrokerageError.unsupported(method: "priceHistory")
  }
  // NOTE: portfolioHistory is intentionally NOT implemented — the default
  // extension supplies it.
}

@Suite("portfolioHistory default extension")
struct PortfolioHistoryTests {
  private let accountID = AccountID(rawValue: "acct-1")

  private func position(
    symbol: String,
    quantity: Decimal,
    marketValue: Decimal,
    at date: Date
  ) -> Position {
    Position(
      accountID: accountID,
      symbol: Symbol(rawValue: symbol),
      assetClass: .equity,
      quantity: quantity,
      averageCost: nil,
      marketValue: Money(marketValue, .usd),
      unrealizedPL: nil,
      asOf: date
    )
  }

  @Test("throws .unsupported when both snapshotStore and marketData are nil")
  func unsupportedWithoutDeps() async {
    let provider = ExtensionTestProvider(snapshotStore: nil, marketData: nil)
    await #expect(throws: BrokerageError.self) {
      _ = try await provider.portfolioHistory(accountID: accountID, range: .oneMonth)
    }
  }

  @Test("sparse snapshots are resampled into points at the granularity step")
  func sparseResampling() async throws {
    // Two snapshots a few days apart within a 1M range (daily granularity).
    let now = Date()
    let interval = TimeRange.oneMonth.interval(now: now)
    let early = interval.start.addingTimeInterval(2 * 86_400)
    let late = interval.end.addingTimeInterval(-2 * 86_400)

    let store = InMemorySnapshotStore()
    try await store.recordSnapshot(
      PortfolioSnapshot(
        accountID: accountID,
        timestamp: early,
        totalValue: Money(1000, .usd),
        positions: [position(symbol: "AMD", quantity: 10, marketValue: 1000, at: early)]
      )
    )
    try await store.recordSnapshot(
      PortfolioSnapshot(
        accountID: accountID,
        timestamp: late,
        totalValue: Money(1200, .usd),
        positions: [position(symbol: "AMD", quantity: 10, marketValue: 1200, at: late)]
      )
    )

    // Market data is flat $100/share, so 10 shares -> $1000 at every resample.
    let market = FixedMarketDataProvider(price: .usd(100))
    let provider = ExtensionTestProvider(snapshotStore: store, marketData: market)

    let series = try await provider.portfolioHistory(accountID: accountID, range: .oneMonth)

    #expect(series.subject == .account(accountID))
    #expect(series.granularity == .oneDay)
    // Daily granularity over ~1 month, but only timestamps at/after the first
    // snapshot are emitted, so we should have many points (one per day from the
    // first snapshot onward) and far more than the 2 raw snapshots.
    #expect(series.points.count > 2)
    // Every emitted point is at or after the first snapshot.
    #expect(series.points.allSatisfy { $0.timestamp >= early })
    // With flat $100 market prices and 10 shares, every replayed point is $1000.
    #expect(series.points.allSatisfy { $0.value == Money(1000, .usd) })
    // Points are at the daily step apart (within a small tolerance).
    if series.points.count >= 2 {
      let delta = series.points[1].timestamp.timeIntervalSince(series.points[0].timestamp)
      #expect(abs(delta - 86_400) < 1)
    }
  }

  @Test("a symbol that does not resolve in market data is carried forward, not dropped")
  func unresolvedSymbolCarriedForward() async throws {
    let now = Date()
    let interval = TimeRange.oneMonth.interval(now: now)
    let snapDate = interval.start.addingTimeInterval(86_400)

    let store = InMemorySnapshotStore()
    // One resolvable symbol and one that market data will fail on.
    try await store.recordSnapshot(
      PortfolioSnapshot(
        accountID: accountID,
        timestamp: snapDate,
        totalValue: Money(1500, .usd),
        positions: [
          position(symbol: "AMD", quantity: 10, marketValue: 1000, at: snapDate),
          position(symbol: "PRIVATE-FUND", quantity: 1, marketValue: 500, at: snapDate),
        ]
      )
    )

    // Market provider resolves AMD at $100 but throws for everything else.
    let market = SelectiveMarketDataProvider(
      resolvable: [Symbol(rawValue: "AMD"): .usd(100)]
    )
    let provider = ExtensionTestProvider(snapshotStore: store, marketData: market)

    let series = try await provider.portfolioHistory(accountID: accountID, range: .oneMonth)

    #expect(!series.points.isEmpty)
    // AMD replays to 10 * $100 = $1000; PRIVATE-FUND is carried at its snapshot
    // market value of $500. Total = $1500 — the position is NOT dropped.
    #expect(series.points.allSatisfy { $0.value == Money(1500, .usd) })
  }

  @Test("empty store yields an empty series")
  func emptyStore() async throws {
    let store = InMemorySnapshotStore()
    let market = FixedMarketDataProvider(price: .usd(100))
    let provider = ExtensionTestProvider(snapshotStore: store, marketData: market)
    let series = try await provider.portfolioHistory(accountID: accountID, range: .oneMonth)
    #expect(series.points.isEmpty)
    #expect(series.subject == .account(accountID))
  }
}

/// A ``MarketDataProvider`` that resolves only a known set of symbols and throws
/// ``BrokerageError/missingSymbol(_:)`` for everything else, so tests can drive
/// the carry-forward path for unresolved symbols.
private struct SelectiveMarketDataProvider: MarketDataProvider {
  let resolvable: [Symbol: Money]

  func quote(symbol: Symbol) async throws -> Quote {
    guard let price = resolvable[symbol] else {
      throw BrokerageError.missingSymbol(symbol)
    }
    return Quote(symbol: symbol, last: price, previousClose: price, asOf: .now)
  }

  func priceHistory(symbol: Symbol, range: TimeRange) async throws -> PerformanceSeries {
    guard let price = resolvable[symbol] else {
      throw BrokerageError.missingSymbol(symbol)
    }
    let interval = range.interval()
    return PerformanceSeries(
      subject: .symbol(symbol),
      range: range,
      points: [
        PerformanceSeries.Point(timestamp: interval.start, value: price),
        PerformanceSeries.Point(timestamp: interval.end, value: price),
      ],
      granularity: range.granularity
    )
  }
}
