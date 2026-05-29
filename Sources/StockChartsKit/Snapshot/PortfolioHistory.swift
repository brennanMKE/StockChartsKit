import Foundation
import os

extension BrokerageProvider {
  /// Reconstructs an account's portfolio-value series from the provider's
  /// injected ``snapshotStore`` and ``marketData``.
  ///
  /// This is the default implementation every provider inherits. Providers that
  /// expose ``Capabilities/nativePortfolioHistory`` override this directly and
  /// ignore the injected dependencies (none do in v1).
  ///
  /// ## Algorithm
  /// 1. Pull all snapshots for `accountID` within `range.interval()` from
  ///    ``snapshotStore``, oldest first.
  /// 2. Build a value point for each *resample* timestamp stepped at
  ///    `range.granularity` across the interval (plus the interval end). For
  ///    each resample timestamp, take the nearest snapshot at or before it and
  ///    *replay* its positions: each position is revalued at the market price
  ///    for the resample timestamp (from ``marketData``'s price history for the
  ///    symbol, using the nearest point at or before the timestamp). Summing the
  ///    revalued positions yields the point's value — this fills the gaps
  ///    between sparse snapshots with market-driven values.
  /// 3. **Carry-forward:** a position whose symbol does not resolve in market
  ///    data (the call throws, or the history has no usable point) is carried at
  ///    its last known snapshot ``Position/marketValue`` — it is **never
  ///    dropped**. If a snapshot has no positions at all, the snapshot's
  ///    ``PortfolioSnapshot/totalValue`` is used directly.
  /// 4. Return a ``PerformanceSeries`` with `subject = .account(accountID)` and
  ///    `granularity = range.granularity`.
  ///
  /// ## Resampling choice
  /// Resampling uses a fixed step derived from `range.granularity` and a
  /// nearest-prior (step-function / last-observation-carried-forward) lookup for
  /// both snapshots and market prices. This is deterministic and avoids
  /// fabricating values before the first snapshot: resample timestamps earlier
  /// than the first snapshot are skipped, so the series starts at the first
  /// real data point.
  ///
  /// - Throws: ``BrokerageError/unsupported(method:)`` when **both**
  ///   ``snapshotStore`` and ``marketData`` are `nil`.
  public func portfolioHistory(
    accountID: AccountID,
    range: TimeRange
  ) async throws -> PerformanceSeries {
    guard snapshotStore != nil || marketData != nil else {
      throw BrokerageError.unsupported(method: "portfolioHistory")
    }
    let log = Logger(
      subsystem: "co.sstools.stockchartskit",
      category: "PortfolioHistory"
    )

    let interval = range.interval()
    let granularity = range.granularity

    // Without a snapshot store there is nothing to reconstruct from; an empty
    // series is the honest answer (market data alone has no account positions).
    guard let store = snapshotStore else {
      return PerformanceSeries(
        subject: .account(accountID),
        range: range,
        points: [],
        granularity: granularity
      )
    }

    let snapshots = try await store.snapshots(accountID: accountID, in: interval)
    guard !snapshots.isEmpty else {
      return PerformanceSeries(
        subject: .account(accountID),
        range: range,
        points: [],
        granularity: granularity
      )
    }

    // Pre-fetch per-symbol price history once per symbol (across all snapshots)
    // so we do not refetch for every resample timestamp. A symbol that fails to
    // resolve maps to `nil`, signalling carry-forward at replay time.
    let symbols = Set(snapshots.flatMap { $0.positions.map(\.symbol) })
    var priceHistories: [Symbol: [PerformanceSeries.Point]] = [:]
    if let market = marketData {
      for symbol in symbols {
        do {
          let series = try await market.priceHistory(symbol: symbol, range: range)
          priceHistories[symbol] = series.points.sorted { $0.timestamp < $1.timestamp }
        } catch {
          // Unresolved symbol: leave it out of the map so replay carries it
          // forward at its last known snapshot value (never dropped).
          log.debug("Market data unavailable for a symbol; carrying snapshot value forward")
        }
      }
    }

    let timestamps = Self.resampleTimestamps(in: interval, granularity: granularity)
    var points: [PerformanceSeries.Point] = []
    points.reserveCapacity(timestamps.count)

    for timestamp in timestamps {
      // Nearest snapshot at or before this resample timestamp. Skip timestamps
      // before the first snapshot so we never fabricate pre-history values.
      guard let snapshot = Self.nearestPriorSnapshot(snapshots, at: timestamp) else {
        continue
      }
      let value = Self.value(
        of: snapshot,
        at: timestamp,
        priceHistories: priceHistories
      )
      points.append(PerformanceSeries.Point(timestamp: timestamp, value: value))
    }

    return PerformanceSeries(
      subject: .account(accountID),
      range: range,
      points: points,
      granularity: granularity
    )
  }

  // MARK: Replay

  /// The portfolio value of `snapshot` revalued at `timestamp`.
  ///
  /// Each position is revalued as `quantity × marketPrice(symbol, timestamp)`.
  /// When market data for the symbol is unavailable (not in `priceHistories`) or
  /// has no point at/before `timestamp`, the position is carried at its stored
  /// snapshot ``Position/marketValue`` (never dropped). A snapshot with no
  /// positions falls back to its ``PortfolioSnapshot/totalValue``.
  private static func value(
    of snapshot: PortfolioSnapshot,
    at timestamp: Date,
    priceHistories: [Symbol: [PerformanceSeries.Point]]
  ) -> Money {
    guard !snapshot.positions.isEmpty else {
      return snapshot.totalValue
    }
    let currency = snapshot.totalValue.currency
    var total = Decimal.zero
    for position in snapshot.positions {
      if let history = priceHistories[position.symbol],
        let price = nearestPriorPrice(history, at: timestamp) {
        total += position.quantity * price.amount
      } else {
        // Carry forward at the last known snapshot market value.
        total += position.marketValue.amount
      }
    }
    return Money(total, currency)
  }

  // MARK: Resampling helpers

  /// The seconds between samples for a granularity.
  private static func stepSeconds(_ granularity: Granularity) -> TimeInterval {
    switch granularity {
    case .oneMinute: return 60
    case .fiveMinutes: return 300
    case .fifteenMinutes: return 900
    case .oneHour: return 3600
    case .oneDay: return 86_400
    case .oneWeek: return 604_800
    }
  }

  /// Resample timestamps stepped across `interval`, always including the end.
  ///
  /// `.distantPast`-anchored intervals (range `.max`) are clamped to a bounded
  /// number of steps back from the end so reconstruction stays finite.
  private static func resampleTimestamps(
    in interval: DateInterval,
    granularity: Granularity
  ) -> [Date] {
    let step = stepSeconds(granularity)
    let end = interval.end
    // Cap the number of samples so a `.distantPast` start cannot explode.
    let maxSamples = 5_000
    let spanned = interval.duration / step
    let count = min(Int(spanned.rounded(.down)) + 1, maxSamples)
    guard count > 0 else { return [end] }
    var timestamps: [Date] = []
    timestamps.reserveCapacity(count + 1)
    for i in stride(from: count - 1, through: 0, by: -1) {
      timestamps.append(end.addingTimeInterval(-Double(i) * step))
    }
    if timestamps.last != end {
      timestamps.append(end)
    }
    return timestamps
  }

  /// The most recent snapshot at or before `timestamp`, or `nil` when all
  /// snapshots are after it. Snapshots are assumed oldest-first.
  private static func nearestPriorSnapshot(
    _ snapshots: [PortfolioSnapshot],
    at timestamp: Date
  ) -> PortfolioSnapshot? {
    var match: PortfolioSnapshot?
    for snapshot in snapshots {
      if snapshot.timestamp <= timestamp {
        match = snapshot
      } else {
        break
      }
    }
    return match
  }

  /// The most recent price point at or before `timestamp`, or `nil` when all
  /// points are after it. Points are assumed oldest-first.
  private static func nearestPriorPrice(
    _ points: [PerformanceSeries.Point],
    at timestamp: Date
  ) -> Money? {
    var match: Money?
    for point in points {
      if point.timestamp <= timestamp {
        match = point.value
      } else {
        break
      }
    }
    return match
  }
}
