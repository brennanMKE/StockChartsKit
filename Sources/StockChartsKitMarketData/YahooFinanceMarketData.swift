import Foundation
import StockChartsKit
import os

/// The fallback ``MarketDataProvider``, backed by Yahoo Finance's chart
/// endpoint (`https://query1.finance.yahoo.com/v8/finance/chart/{symbol}`).
///
/// This endpoint is undocumented and unauthenticated; it is widely used but
/// carries a legal grey area (see `README.md`). Treat it as best-effort — the
/// tiered provider only reaches Yahoo when the primary fails.
///
/// The response packs parallel arrays: a `timestamp` array and an
/// `indicators.quote[0].close` array of the same length. This provider zips them
/// into a ``PerformanceSeries``.
public struct YahooFinanceMarketData: MarketDataProvider {
  private let client: HTTPClient
  private let now: @Sendable () -> Date
  private static let providerID = ProviderID(rawValue: "yahoo")

  /// Creates a Yahoo Finance market-data provider.
  ///
  /// - Parameters:
  ///   - session: The `URLSession` used for requests. Inject a replay-backed
  ///     session in tests; defaults to `.shared` in production.
  ///   - retryPolicy: The HTTP retry policy. Defaults to ``RetryPolicy/default``.
  ///   - sleep: The wait primitive between retry attempts. Defaults to
  ///     `Task.sleep`; tests inject a no-op to avoid real delays.
  ///   - now: Supplies the current date. Defaults to `Date.init`.
  public init(
    session: URLSession = .shared,
    retryPolicy: RetryPolicy = .default,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.now = now
    self.client = HTTPClient(
      providerID: Self.providerID,
      session: session,
      retryPolicy: retryPolicy,
      sleep: sleep
    )
  }

  // MARK: MarketDataProvider

  public func quote(symbol: Symbol) async throws -> Quote {
    // A 1-day, 1-minute chart yields the latest close plus the prior day's
    // close (`chartPreviousClose`) — enough to build a quote.
    let chart = try await fetchChart(symbol: symbol, interval: "1m", range: "1d")
    let result = try Self.firstResult(chart, symbol: symbol)
    let closes = result.indicators?.quote?.first?.close ?? []
    let lastClose = closes.compactMap { $0?.wrappedValue }.last
    guard let lastValue = lastClose ?? result.meta?.regularMarketPrice?.wrappedValue else {
      throw BrokerageError.missingSymbol(symbol)
    }
    let currency = result.meta?.currency.map { CurrencyCode(rawValue: $0) } ?? .usd
    let previousClose = result.meta?.chartPreviousClose?.wrappedValue
      ?? result.meta?.previousClose?.wrappedValue
    let asOf = result.meta?.regularMarketTime.map(Date.init(timeIntervalSince1970:)) ?? now()
    return Quote(
      symbol: symbol,
      last: Money(lastValue, currency),
      previousClose: previousClose.map { Money($0, currency) },
      asOf: asOf
    )
  }

  public func priceHistory(
    symbol: Symbol,
    range: TimeRange
  ) async throws -> PerformanceSeries {
    let (interval, yahooRange) = Self.mapping(for: range)
    let chart = try await fetchChart(symbol: symbol, interval: interval, range: yahooRange)
    let result = try Self.firstResult(chart, symbol: symbol)
    let timestamps = result.timestamp ?? []
    let closes = result.indicators?.quote?.first?.close ?? []
    let currency = result.meta?.currency.map { CurrencyCode(rawValue: $0) } ?? .usd

    var points: [PerformanceSeries.Point] = []
    points.reserveCapacity(min(timestamps.count, closes.count))
    for index in 0..<min(timestamps.count, closes.count) {
      guard let close = closes[index]?.wrappedValue else { continue }
      let timestamp = Date(timeIntervalSince1970: TimeInterval(timestamps[index]))
      points.append(.init(timestamp: timestamp, value: Money(close, currency)))
    }
    return PerformanceSeries(
      subject: .symbol(symbol),
      range: range,
      points: points,
      granularity: range.granularity
    )
  }

  // MARK: Networking

  private func fetchChart(
    symbol: Symbol,
    interval: String,
    range: String
  ) async throws -> YahooChartResponse {
    var components = URLComponents()
    components.scheme = "https"
    components.host = "query1.finance.yahoo.com"
    components.path = "/v8/finance/chart/\(symbol.rawValue)"
    components.queryItems = [
      URLQueryItem(name: "interval", value: interval),
      URLQueryItem(name: "range", value: range),
    ]
    guard let url = components.url else {
      throw BrokerageError.network(underlying: URLError(.badURL))
    }
    return try await client.send(URLRequest(url: url), expecting: YahooChartResponse.self)
  }

  private static func firstResult(
    _ chart: YahooChartResponse,
    symbol: Symbol
  ) throws -> YahooChartResult {
    guard let result = chart.chart?.result?.first else {
      throw BrokerageError.missingSymbol(symbol)
    }
    return result
  }

  /// Maps a ``TimeRange`` to Yahoo's `interval` and `range` query parameters.
  ///
  /// Yahoo expects coarse granularities for long ranges; requesting a fine
  /// interval over a multi-year range is rejected. The mapping mirrors
  /// ``TimeRange/granularity``.
  static func mapping(for range: TimeRange) -> (interval: String, range: String) {
    switch range {
    case .oneDay: return ("1m", "1d")
    case .oneWeek: return ("15m", "5d")
    case .oneMonth: return ("1d", "1mo")
    case .threeMonths: return ("1d", "3mo")
    case .yearToDate: return ("1d", "ytd")
    case .oneYear: return ("1d", "1y")
    case .fiveYears: return ("1wk", "5y")
    case .max: return ("1wk", "max")
    }
  }
}

// MARK: - Wire types

private struct YahooChartResponse: Decodable {
  let chart: YahooChart?
}

private struct YahooChart: Decodable {
  let result: [YahooChartResult]?
}

private struct YahooChartResult: Decodable {
  let meta: YahooChartMeta?
  let timestamp: [Int]?
  let indicators: YahooIndicators?
}

private struct YahooChartMeta: Decodable {
  let currency: String?
  let regularMarketPrice: LossyDecimal?
  let chartPreviousClose: LossyDecimal?
  let previousClose: LossyDecimal?
  let regularMarketTime: TimeInterval?
}

private struct YahooIndicators: Decodable {
  let quote: [YahooQuoteSeries]?
}

private struct YahooQuoteSeries: Decodable {
  /// The close array parallels the result's `timestamp` array. Entries may be
  /// `null` for gaps (holidays, halted trading), so the element is optional.
  let close: [LossyDecimal?]?
}
