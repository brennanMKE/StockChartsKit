import Foundation
import StockChartsKit

/// A single end-of-day closing bar for a symbol.
///
/// The cache stores these per symbol so the tiered provider can satisfy daily
/// price-history requests without re-hitting the network for ranges it has
/// already fetched. Each bar carries the exact `date` it represents so the
/// returned ``PerformanceSeries`` can report an accurate `asOf`.
public struct DailyBar: Hashable, Sendable, Codable {
  /// The calendar day the close was observed (provider-supplied, UTC).
  public let date: Date
  /// The closing price for that day.
  public let close: Decimal
  /// The currency the close is expressed in.
  public let currency: CurrencyCode

  /// Creates a daily bar.
  public init(date: Date, close: Decimal, currency: CurrencyCode = .usd) {
    self.date = date
    self.close = close
    self.currency = currency
  }
}

/// A local cache of fetched daily bars, keyed by symbol.
///
/// Per PRD §6, the tiered provider serves daily granularity cache-first and only
/// hits the network for missing or stale ranges, keeping a multi-symbol
/// portfolio under Tiingo's free-tier quota. Intraday (`1D`) is never cached and
/// is fetched live each time.
///
/// Implementations must be safe to use concurrently. The package ships an
/// in-memory default (``InMemoryDailyBarCache``); a host may inject a persistent
/// implementation (e.g. backed by the snapshot SQLite database).
public protocol DailyBarCache: Sendable {
  /// Returns the cached bars for `symbol` whose `date` falls within `interval`,
  /// ordered oldest to newest. Returns an empty array when nothing is cached.
  func bars(symbol: Symbol, in interval: DateInterval) async -> [DailyBar]

  /// Merges `bars` into the cache for `symbol`, replacing any existing bar that
  /// shares a calendar day.
  func store(_ bars: [DailyBar], symbol: Symbol) async
}

/// An in-memory ``DailyBarCache`` backed by an actor.
///
/// Suitable for tests and for hosts that do not need cache persistence across
/// launches. Bars are deduplicated by calendar day (UTC) and kept sorted.
public actor InMemoryDailyBarCache: DailyBarCache {
  private var storage: [Symbol: [Date: DailyBar]] = [:]
  private let calendar: Calendar

  /// Creates an empty cache.
  ///
  /// - Parameter calendar: The calendar used to bucket bars by day. Defaults to
  ///   a UTC Gregorian calendar so day boundaries are stable regardless of the
  ///   host's locale.
  public init(calendar: Calendar = InMemoryDailyBarCache.utcCalendar) {
    self.calendar = calendar
  }

  public func bars(symbol: Symbol, in interval: DateInterval) async -> [DailyBar] {
    guard let byDay = storage[symbol] else { return [] }
    return
      byDay.values
      .filter { interval.contains($0.date) }
      .sorted { $0.date < $1.date }
  }

  public func store(_ bars: [DailyBar], symbol: Symbol) async {
    guard !bars.isEmpty else { return }
    var byDay = storage[symbol] ?? [:]
    for bar in bars {
      let day = calendar.startOfDay(for: bar.date)
      byDay[day] = DailyBar(date: bar.date, close: bar.close, currency: bar.currency)
    }
    storage[symbol] = byDay
  }

  /// A Gregorian calendar pinned to UTC for stable day bucketing.
  public static let utcCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    return calendar
  }()
}
