import Foundation

/// A chart time range, matching the Robinhood chart selector exactly.
public enum TimeRange: String, CaseIterable, Sendable, Codable {
  /// One day (`"1D"`).
  case oneDay = "1D"
  /// One week (`"1W"`).
  case oneWeek = "1W"
  /// One month (`"1M"`).
  case oneMonth = "1M"
  /// Three months (`"3M"`).
  case threeMonths = "3M"
  /// Year to date (`"YTD"`), anchored at January 1 of the current year.
  case yearToDate = "YTD"
  /// One year (`"1Y"`).
  case oneYear = "1Y"
  /// Five years (`"5Y"`).
  case fiveYears = "5Y"
  /// All available history (`"MAX"`).
  case max = "MAX"

  /// The `(start, end)` date interval for this range, anchored at `now`.
  ///
  /// For ``max`` this returns `(.distantPast, now)`; the provider clamps the
  /// start to its available history. ``yearToDate`` anchors the start at
  /// January 1 of `now`'s year in `calendar`. All other ranges subtract a
  /// calendar component (days, months, or years) from `now`, so they respect
  /// DST transitions, leap days, and year boundaries.
  public func interval(now: Date = .now, calendar: Calendar = .current) -> DateInterval {
    let start: Date
    switch self {
    case .oneDay:
      start = calendar.date(byAdding: .day, value: -1, to: now) ?? now
    case .oneWeek:
      start = calendar.date(byAdding: .day, value: -7, to: now) ?? now
    case .oneMonth:
      start = calendar.date(byAdding: .month, value: -1, to: now) ?? now
    case .threeMonths:
      start = calendar.date(byAdding: .month, value: -3, to: now) ?? now
    case .yearToDate:
      let components = calendar.dateComponents([.year], from: now)
      start = calendar.date(from: components) ?? now
    case .oneYear:
      start = calendar.date(byAdding: .year, value: -1, to: now) ?? now
    case .fiveYears:
      start = calendar.date(byAdding: .year, value: -5, to: now) ?? now
    case .max:
      start = .distantPast
    }
    // Guard against a computed start after `now` (e.g. from a calendar edge).
    let safeStart = min(start, now)
    return DateInterval(start: safeStart, end: now)
  }

  /// The recommended sample granularity for this range, used as a hint to
  /// providers that support it (e.g. 1-minute candles for ``oneDay``, daily
  /// for ranges of a month or more).
  public var granularity: Granularity {
    switch self {
    case .oneDay:
      return .oneMinute
    case .oneWeek:
      return .fifteenMinutes
    case .oneMonth, .threeMonths:
      return .oneDay
    case .yearToDate, .oneYear:
      return .oneDay
    case .fiveYears, .max:
      return .oneWeek
    }
  }
}

/// A recommended candle/sample granularity for a price or value series.
public enum Granularity: Hashable, Sendable, Codable {
  /// One-minute samples.
  case oneMinute
  /// Five-minute samples.
  case fiveMinutes
  /// Fifteen-minute samples.
  case fifteenMinutes
  /// One-hour samples.
  case oneHour
  /// One-day samples.
  case oneDay
  /// One-week samples.
  case oneWeek
}
