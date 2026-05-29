import Foundation

/// A time series of monetary values backing every chart.
///
/// A `PerformanceSeries` describes a subject (a symbol, an account, or an
/// aggregated portfolio), a time range, the sampled points, and the
/// granularity at which they were sampled.
public struct PerformanceSeries: Hashable, Sendable, Codable {
  /// What the series describes.
  public let subject: Subject
  /// The range the series covers.
  public let range: TimeRange
  /// The sampled points, ordered oldest to newest.
  public let points: [Point]
  /// The granularity at which the points were sampled.
  public let granularity: Granularity

  /// Creates a performance series.
  public init(
    subject: Subject,
    range: TimeRange,
    points: [Point],
    granularity: Granularity
  ) {
    self.subject = subject
    self.range = range
    self.points = points
    self.granularity = granularity
  }

  /// A single sampled value at a point in time.
  public struct Point: Hashable, Sendable, Codable {
    /// When the value was observed.
    public let timestamp: Date
    /// The value at `timestamp`.
    public let value: Money

    /// Creates a point.
    public init(timestamp: Date, value: Money) {
      self.timestamp = timestamp
      self.value = value
    }
  }

  /// What a ``PerformanceSeries`` describes.
  public enum Subject: Hashable, Sendable, Codable {
    /// A single symbol's price history.
    case symbol(Symbol)
    /// A single account's value history.
    case account(AccountID)
    /// A portfolio's value history; `nil` provider aggregates across all.
    case portfolio(providerID: ProviderID?)
  }

  /// Start value, end value, absolute change, and percent change for the
  /// series, or `nil` when ``points`` is empty.
  ///
  /// Mirrors the "$+290.85 (+145.35%)" header in a chart. ``Summary/percentChange``
  /// is `nil` when the start value is zero (a position opened mid-range).
  public var summary: Summary? {
    guard let first = points.first, let last = points.last else {
      return nil
    }
    let start = first.value
    let end = last.value
    let absoluteChange = Money(end.amount - start.amount, start.currency)
    let percentChange: Decimal?
    if start.amount == 0 {
      percentChange = nil
    } else {
      percentChange = (end.amount - start.amount) / start.amount
    }
    return Summary(
      start: start,
      end: end,
      absoluteChange: absoluteChange,
      percentChange: percentChange
    )
  }

  /// A summary of a ``PerformanceSeries``'s change over its range.
  public struct Summary: Sendable {
    /// The value at the start of the series.
    public let start: Money
    /// The value at the end of the series.
    public let end: Money
    /// The absolute change from start to end.
    public let absoluteChange: Money
    /// The fractional change (e.g. `1.4535` for +145.35%), or `nil` when the
    /// start value is zero.
    public let percentChange: Decimal?

    /// Creates a summary.
    public init(
      start: Money,
      end: Money,
      absoluteChange: Money,
      percentChange: Decimal?
    ) {
      self.start = start
      self.end = end
      self.absoluteChange = absoluteChange
      self.percentChange = percentChange
    }
  }
}
