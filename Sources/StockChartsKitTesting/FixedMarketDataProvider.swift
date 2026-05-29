import Foundation
import StockChartsKit

/// A ``MarketDataProvider`` that returns fixed, canned data for every symbol.
///
/// Useful when a test needs a market-data dependency but does not care about the
/// specific values. By default it returns a `$100.00` quote and a flat
/// two-point `$100.00` series; both are configurable via the initializer.
///
/// The provider is a `Sendable` value type with no mutable state, so it is safe
/// to share across tasks under strict concurrency.
public struct FixedMarketDataProvider: MarketDataProvider {
  /// The price returned for every quote and price-history point.
  public let price: Money

  /// The granularity reported by ``priceHistory(symbol:range:)``; when `nil`,
  /// the range's recommended ``TimeRange/granularity`` is used.
  public let granularity: Granularity?

  /// Creates a fixed market-data provider.
  ///
  /// - Parameters:
  ///   - price: The price returned for quotes and every history point.
  ///     Defaults to `$100.00`.
  ///   - granularity: An override granularity for price history; when `nil`
  ///     (the default) the requested range's recommended granularity is used.
  public init(
    price: Money = .usd(100),
    granularity: Granularity? = nil
  ) {
    self.price = price
    self.granularity = granularity
  }

  public func quote(symbol: Symbol) async throws -> Quote {
    Quote(symbol: symbol, last: price, previousClose: price, asOf: .now)
  }

  public func priceHistory(
    symbol: Symbol,
    range: TimeRange
  ) async throws -> PerformanceSeries {
    let interval = range.interval()
    let points = [
      PerformanceSeries.Point(timestamp: interval.start, value: price),
      PerformanceSeries.Point(timestamp: interval.end, value: price),
    ]
    return PerformanceSeries(
      subject: .symbol(symbol),
      range: range,
      points: points,
      granularity: granularity ?? range.granularity
    )
  }
}
