import Foundation

/// A source of per-symbol market data, independent of any brokerage account.
///
/// Many brokerages do not expose per-symbol charting history. A host supplies
/// (or defaults to) a `MarketDataProvider` so a `BrokerageProvider` that lacks
/// native history can still reconstruct charts. The default implementation lives
/// in `StockChartsKitMarketData`; the host may inject any other source.
public protocol MarketDataProvider: Sendable {
  /// Returns the current quote for `symbol`.
  func quote(symbol: Symbol) async throws -> Quote

  /// Returns the price history for `symbol` over `range`.
  func priceHistory(symbol: Symbol, range: TimeRange) async throws -> PerformanceSeries
}
