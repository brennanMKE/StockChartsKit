import Foundation
import StockChartsKit
import os

/// The default composite ``MarketDataProvider``: tries `primary` first and falls
/// back to `fallback` on **any** error.
///
/// Per PRD §6 this wires Tiingo (primary) ahead of Yahoo (fallback) and adds a
/// local ``DailyBarCache`` so daily price history is served cache-first, only
/// reaching the network for ranges not already cached. Intraday (`1D`) is never
/// cached and is fetched live on every call.
///
/// ## Quota and caching
/// Daily bars fetched from either tier are written to the cache keyed by symbol.
/// A subsequent daily request whose range is fully covered by the cache returns
/// without any network call, keeping a multi-symbol portfolio under Tiingo's
/// free-tier quota. The returned series reports an accurate `asOf` via its
/// newest point, so stale data is never presented as fresh.
///
/// ## Example
/// ```swift
/// let marketData = TieredMarketDataProvider(
///   primary: TiingoMarketData(apiKey: try await keychain.secret("tiingo.apiKey")),
///   fallback: YahooFinanceMarketData()
/// )
/// ```
public struct TieredMarketDataProvider: MarketDataProvider {
  private let primary: any MarketDataProvider
  private let fallback: any MarketDataProvider
  private let cache: any DailyBarCache
  private let now: @Sendable () -> Date
  private let calendar: Calendar
  private let logger = Logger(
    subsystem: "co.sstools.stockchartskit",
    category: "marketdata"
  )

  /// Creates a tiered provider.
  ///
  /// - Parameters:
  ///   - primary: The preferred source (typically ``TiingoMarketData``).
  ///   - fallback: The source used when `primary` throws (typically
  ///     ``YahooFinanceMarketData``).
  ///   - cache: The daily-bar cache. Defaults to an in-memory cache; inject a
  ///     persistent implementation to survive launches.
  ///   - now: Supplies the current date for range math. Defaults to `Date.init`.
  ///   - calendar: The calendar used for range math. Defaults to `.current`.
  public init(
    primary: any MarketDataProvider,
    fallback: any MarketDataProvider,
    cache: any DailyBarCache = InMemoryDailyBarCache(),
    now: @escaping @Sendable () -> Date = Date.init,
    calendar: Calendar = .current
  ) {
    self.primary = primary
    self.fallback = fallback
    self.cache = cache
    self.now = now
    self.calendar = calendar
  }

  // MARK: MarketDataProvider

  /// Returns a quote, trying the primary first and the fallback on any error.
  ///
  /// Quotes are real-time and are never cached.
  public func quote(symbol: Symbol) async throws -> Quote {
    do {
      return try await primary.quote(symbol: symbol)
    } catch {
      logger.debug("Primary quote failed; falling back: \(String(describing: error))")
      return try await fallback.quote(symbol: symbol)
    }
  }

  /// Returns price history.
  ///
  /// - Intraday (`1D`) is fetched live from primary→fallback and never cached.
  /// - Daily granularity is served cache-first: a fully covered range returns
  ///   from the cache with no network call; otherwise the bars are fetched,
  ///   cached, and returned.
  public func priceHistory(
    symbol: Symbol,
    range: TimeRange
  ) async throws -> PerformanceSeries {
    guard range.granularity == .oneDay else {
      // Intraday and weekly-sampled ranges bypass the daily cache and fetch live.
      return try await fetchLive(symbol: symbol, range: range)
    }

    let interval = range.interval(now: now(), calendar: calendar)
    let cached = await cache.bars(symbol: symbol, in: interval)
    if Self.covers(cached, interval: interval, calendar: calendar) {
      logger.debug("Serving \(range.rawValue, privacy: .public) from cache")
      return TiingoMarketData.makeSeries(symbol: symbol, range: range, bars: cached)
    }

    let bars = try await fetchBars(symbol: symbol, range: range)
    await cache.store(bars, symbol: symbol)
    return TiingoMarketData.makeSeries(symbol: symbol, range: range, bars: bars)
  }

  // MARK: Fetching

  /// Fetches daily bars, preferring the primary's typed bar path so they can be
  /// cached, and falling back to deriving bars from the fallback's series.
  private func fetchBars(symbol: Symbol, range: TimeRange) async throws -> [DailyBar] {
    if let tiingo = primary as? TiingoMarketData {
      do {
        return try await tiingo.dailyBars(symbol: symbol, range: range)
      } catch {
        logger.debug("Primary daily fetch failed; falling back: \(String(describing: error))")
        return try await fallbackBars(symbol: symbol, range: range)
      }
    }
    // A non-Tiingo primary: derive bars from its series, falling back on error.
    do {
      let series = try await primary.priceHistory(symbol: symbol, range: range)
      return Self.bars(from: series)
    } catch {
      logger.debug("Primary series fetch failed; falling back: \(String(describing: error))")
      return try await fallbackBars(symbol: symbol, range: range)
    }
  }

  private func fallbackBars(symbol: Symbol, range: TimeRange) async throws -> [DailyBar] {
    let series = try await fallback.priceHistory(symbol: symbol, range: range)
    return Self.bars(from: series)
  }

  private func fetchLive(symbol: Symbol, range: TimeRange) async throws -> PerformanceSeries {
    do {
      return try await primary.priceHistory(symbol: symbol, range: range)
    } catch {
      logger.debug("Primary history failed; falling back: \(String(describing: error))")
      return try await fallback.priceHistory(symbol: symbol, range: range)
    }
  }

  // MARK: Cache coverage

  /// Whether `bars` cover `interval` densely enough to skip the network.
  ///
  /// Markets are closed on weekends and holidays, so a daily series never has a
  /// bar for every calendar day. We treat the range as covered when there is at
  /// least one bar and the newest bar reaches the most recent expected trading
  /// day — i.e. no fresher data is missing at the tail. This is the freshness
  /// guarantee behind the series' `asOf`.
  static func covers(
    _ bars: [DailyBar],
    interval: DateInterval,
    calendar: Calendar
  ) -> Bool {
    guard let newest = bars.map(\.date).max() else { return false }
    let expectedLatest = mostRecentTradingDay(onOrBefore: interval.end, calendar: calendar)
    return calendar.startOfDay(for: newest) >= calendar.startOfDay(for: expectedLatest)
  }

  /// The most recent weekday on or before `date` (a coarse trading-day proxy
  /// that ignores market holidays, erring toward a refetch when in doubt).
  static func mostRecentTradingDay(onOrBefore date: Date, calendar: Calendar) -> Date {
    var day = calendar.startOfDay(for: date)
    for _ in 0..<7 {
      let weekday = calendar.component(.weekday, from: day)
      // 1 == Sunday, 7 == Saturday in the Gregorian calendar.
      if weekday != 1 && weekday != 7 { return day }
      day = calendar.date(byAdding: .day, value: -1, to: day) ?? day
    }
    return day
  }

  /// Converts a daily ``PerformanceSeries`` into ``DailyBar`` values for caching.
  static func bars(from series: PerformanceSeries) -> [DailyBar] {
    series.points.map {
      DailyBar(date: $0.timestamp, close: $0.value.amount, currency: $0.value.currency)
    }
  }
}
