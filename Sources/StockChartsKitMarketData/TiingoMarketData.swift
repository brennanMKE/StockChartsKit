import Foundation
import StockChartsKit
import os

/// The primary ``MarketDataProvider``, backed by Tiingo (`https://api.tiingo.com`).
///
/// Tiingo's free tier supplies end-of-day daily prices and is the best source
/// for daily charts. The API token is supplied at init by the host (read from
/// the Keychain) and is sent as an `Authorization: Token <token>` header by an
/// injected ``RequestSigner`` — it is never hardcoded and never logged.
///
/// ## Example
/// ```swift
/// let tiingo = TiingoMarketData(apiKey: try await keychain.secret("tiingo.apiKey"))
/// let series = try await tiingo.priceHistory(symbol: Symbol(rawValue: "AMD"), range: .threeMonths)
/// ```
public struct TiingoMarketData: MarketDataProvider {
  private let client: HTTPClient
  private let now: @Sendable () -> Date
  private let calendar: Calendar
  private static let providerID = ProviderID(rawValue: "tiingo")

  /// Creates a Tiingo market-data provider.
  ///
  /// - Parameters:
  ///   - apiKey: The Tiingo API token, supplied by the host from the Keychain.
  ///     Never hardcode this value.
  ///   - session: The `URLSession` used for requests. Inject a replay-backed
  ///     session in tests; defaults to `.shared` in production.
  ///   - retryPolicy: The HTTP retry policy. Defaults to ``RetryPolicy/default``.
  ///   - sleep: The wait primitive between retry attempts. Defaults to
  ///     `Task.sleep`; tests inject a no-op to avoid real delays.
  ///   - now: Supplies the current date for range math. Defaults to `Date.init`.
  ///   - calendar: The calendar used for range math. Defaults to `.current`.
  public init(
    apiKey: String,
    session: URLSession = .shared,
    retryPolicy: RetryPolicy = .default,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    now: @escaping @Sendable () -> Date = Date.init,
    calendar: Calendar = .current
  ) {
    self.now = now
    self.calendar = calendar
    // Capture the token only in the signer closure so it is not retained as a
    // stored property longer than necessary.
    let token = apiKey
    self.client = HTTPClient(
      providerID: Self.providerID,
      session: session,
      signer: RequestSigner { request in
        var signed = request
        // Tiingo accepts the token as an Authorization header; this keeps it
        // out of the URL (and therefore out of logs and fixtures).
        signed.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        return signed
      },
      retryPolicy: retryPolicy,
      sleep: sleep
    )
  }

  // MARK: MarketDataProvider

  public func quote(symbol: Symbol) async throws -> Quote {
    // Tiingo's IEX endpoint returns the latest tradable price for a ticker.
    let request = try makeRequest(path: "/iex/\(symbol.rawValue)")
    let rows = try await client.send(request, expecting: [TiingoIEXQuote].self)
    guard let row = rows.first else {
      throw BrokerageError.missingSymbol(symbol)
    }
    let last = row.last ?? row.tngoLast ?? row.prevClose
    guard let lastValue = last?.wrappedValue else {
      throw BrokerageError.missingSymbol(symbol)
    }
    let previousClose = row.prevClose.map { Money($0.wrappedValue) }
    return Quote(
      symbol: symbol,
      last: Money(lastValue),
      previousClose: previousClose,
      asOf: row.timestamp ?? now()
    )
  }

  public func priceHistory(
    symbol: Symbol,
    range: TimeRange
  ) async throws -> PerformanceSeries {
    let bars = try await dailyBars(symbol: symbol, range: range)
    return Self.makeSeries(symbol: symbol, range: range, bars: bars)
  }

  // MARK: Daily bars (used by the tiered cache)

  /// Fetches daily closing bars for `symbol` over `range` from Tiingo.
  ///
  /// Exposed to ``TieredMarketDataProvider`` so the cache can store and serve
  /// raw bars. The returned bars are ordered oldest to newest.
  func dailyBars(symbol: Symbol, range: TimeRange) async throws -> [DailyBar] {
    let interval = range.interval(now: now(), calendar: calendar)
    var components = URLComponents()
    components.scheme = "https"
    components.host = "api.tiingo.com"
    components.path = "/tiingo/daily/\(symbol.rawValue)/prices"
    var query = [URLQueryItem(name: "format", value: "json")]
    if range != .max {
      query.append(
        URLQueryItem(name: "startDate", value: Self.dateString(interval.start))
      )
    }
    query.append(URLQueryItem(name: "endDate", value: Self.dateString(interval.end)))
    components.queryItems = query
    guard let url = components.url else {
      throw BrokerageError.missingSymbol(symbol)
    }
    let request = URLRequest(url: url)
    let rows = try await client.send(request, expecting: [TiingoDailyPrice].self)
    return rows.compactMap { row in
      guard let date = row.date else { return nil }
      return DailyBar(date: date, close: row.adjClose, currency: .usd)
    }
  }

  // MARK: Helpers

  private func makeRequest(path: String) throws -> URLRequest {
    guard let url = URL(string: "https://api.tiingo.com\(path)") else {
      throw BrokerageError.network(underlying: URLError(.badURL))
    }
    return URLRequest(url: url)
  }

  /// Builds a ``PerformanceSeries`` from cached or freshly fetched daily bars.
  ///
  /// `asOf` is implicit in the points: the newest point's timestamp is the
  /// freshest observation. Shared with ``TieredMarketDataProvider`` so cached
  /// and live results have identical shape.
  static func makeSeries(
    symbol: Symbol,
    range: TimeRange,
    bars: [DailyBar]
  ) -> PerformanceSeries {
    let points = bars
      .sorted { $0.date < $1.date }
      .map { PerformanceSeries.Point(timestamp: $0.date, value: Money($0.close, $0.currency)) }
    return PerformanceSeries(
      subject: .symbol(symbol),
      range: range,
      points: points,
      granularity: .oneDay
    )
  }

  /// Formats a date as `yyyy-MM-dd` (UTC) for Tiingo's date query parameters.
  ///
  /// Uses a UTC `Calendar` rather than a shared `DateFormatter` (which is not
  /// thread-safe) so concurrent requests cannot corrupt shared state.
  static func dateString(_ date: Date) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    let c = calendar.dateComponents([.year, .month, .day], from: date)
    let year = c.year ?? 1970
    let month = c.month ?? 1
    let day = c.day ?? 1
    return String(format: "%04d-%02d-%02d", year, month, day)
  }
}

// MARK: - Wire types

/// A single daily price row from `/tiingo/daily/{symbol}/prices`.
private struct TiingoDailyPrice: Decodable {
  let date: Date?
  @LossyDecimal var adjClose: Decimal

  private enum CodingKeys: String, CodingKey {
    case date
    case adjClose
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    // Tiingo dates are ISO-8601 with a time component, e.g. "2024-01-02T00:00:00.000Z".
    if let raw = try container.decodeIfPresent(String.self, forKey: .date) {
      date = TiingoDailyPrice.parse(raw)
    } else {
      date = nil
    }
    _adjClose = try container.decode(LossyDecimal.self, forKey: .adjClose)
  }

  static func parse(_ raw: String) -> Date? {
    // `ISO8601DateFormatter` parsing is not thread-safe, so guard the shared
    // instances with a lock rather than risk concurrent use across requests.
    formatterLock.lock()
    defer { formatterLock.unlock() }
    if let date = isoWithFraction.date(from: raw) { return date }
    return isoPlain.date(from: raw)
  }

  private static let formatterLock = NSLock()

  // Guarded by `formatterLock`; never accessed outside `parse(_:)`.
  nonisolated(unsafe) private static let isoWithFraction: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  nonisolated(unsafe) private static let isoPlain: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()
}

/// A single quote row from `/iex/{symbol}`.
private struct TiingoIEXQuote: Decodable {
  let timestamp: Date?
  let last: LossyDecimal?
  let tngoLast: LossyDecimal?
  let prevClose: LossyDecimal?

  private enum CodingKeys: String, CodingKey {
    case timestamp
    case last
    case tngoLast
    case prevClose
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let raw = try container.decodeIfPresent(String.self, forKey: .timestamp) {
      timestamp = TiingoDailyPrice.parse(raw)
    } else {
      timestamp = nil
    }
    last = try container.decodeIfPresent(LossyDecimal.self, forKey: .last)
    tngoLast = try container.decodeIfPresent(LossyDecimal.self, forKey: .tngoLast)
    prevClose = try container.decodeIfPresent(LossyDecimal.self, forKey: .prevClose)
  }
}
