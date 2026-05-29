import Foundation
import os

/// Aggregates read-only portfolio data across multiple ``BrokerageProvider``s,
/// FX-converting to a single target currency when summing across accounts.
///
/// The aggregator is an `actor`, so its provider list and dependencies are
/// isolated and the type is `Sendable`-clean. It composes the per-provider
/// reads (``BrokerageProvider/listAccounts()``,
/// ``BrokerageProvider/balance(for:)``,
/// ``BrokerageProvider/portfolioHistory(accountID:range:)``) into portfolio-wide
/// views, doing currency conversion through an injected ``FXService``.
public actor PortfolioAggregator {
  private let providers: [any BrokerageProvider]
  private let snapshotStore: any SnapshotStore
  private let marketData: any MarketDataProvider
  private let fx: any FXService
  private let logger = Logger(
    subsystem: "co.sstools.stockchartskit",
    category: "PortfolioAggregator"
  )

  /// Creates an aggregator.
  ///
  /// - Parameters:
  ///   - providers: The provider backends to aggregate over.
  ///   - snapshotStore: The shared snapshot store backing history reconstruction.
  ///   - marketData: The shared market-data source backing history reconstruction.
  ///   - fx: The FX source used to convert across currencies; defaults to
  ///     ``ECBFXService``.
  public init(
    providers: [any BrokerageProvider],
    snapshotStore: any SnapshotStore,
    marketData: any MarketDataProvider,
    fx: any FXService = ECBFXService()
  ) {
    self.providers = providers
    self.snapshotStore = snapshotStore
    self.marketData = marketData
    self.fx = fx
  }

  // MARK: Accounts

  /// The union of accounts across every provider, in provider order.
  ///
  /// - Throws: Rethrows the first provider error encountered.
  public func allAccounts() async throws -> [Account] {
    var accounts: [Account] = []
    for provider in providers {
      accounts.append(contentsOf: try await provider.listAccounts())
    }
    return accounts
  }

  // MARK: Total value

  /// The summed value of every account, converted into `currency` as of now.
  ///
  /// Each account's ``Balance/total`` is FX-converted via the injected
  /// ``FXService`` and accumulated. Full `Decimal` precision is preserved; no
  /// rounding happens here.
  ///
  /// - Throws: Rethrows the first provider or FX error encountered.
  public func totalValue(in currency: CurrencyCode = .usd) async throws -> Money {
    var sum = Decimal.zero
    let asOf = Date()
    for provider in providers {
      let accounts = try await provider.listAccounts()
      for account in accounts {
        let balance = try await provider.balance(for: account.id)
        let converted = try await fx.convert(balance.total, to: currency, at: asOf)
        sum += converted.amount
      }
    }
    return Money(sum, currency)
  }

  // MARK: Live total values

  /// Streams running cumulative totals (in `currency`) as each provider's
  /// accounts finish loading, so a UI can show partial results while slow
  /// providers catch up.
  ///
  /// Each provider's accounts are loaded concurrently. As a provider completes,
  /// its contribution is added to a running total and the new cumulative total
  /// is emitted. When every provider has reported, the stream finishes.
  ///
  /// ## Error handling
  /// A single provider failure is **surfaced but not fatal**: the error is
  /// logged and that provider contributes `0`, while every other provider's
  /// contribution is preserved and the stream still finishes normally. This
  /// matches the UI goal of showing partial results rather than collapsing the
  /// whole view when one brokerage (e.g. Fidelity) is slow or erroring. The
  /// stream's `Error` element type is retained for callers that inject a
  /// stricter ``FXService`` whose conversion failure should still propagate via
  /// the final summation path of ``totalValue(in:)``.
  public nonisolated func liveTotalValues(
    in currency: CurrencyCode = .usd
  ) -> AsyncThrowingStream<Money, Error> {
    let providers = self.providers
    let fx = self.fx
    let logger = self.logger
    return AsyncThrowingStream { continuation in
      let task = Task {
        let asOf = Date()
        // Compute each provider's contribution concurrently, then fold the
        // results into a running total in completion order.
        await withTaskGroup(of: Decimal.self) { group in
          for provider in providers {
            group.addTask {
              await Self.providerContribution(
                provider,
                in: currency,
                fx: fx,
                asOf: asOf,
                logger: logger
              )
            }
          }
          var running = Decimal.zero
          for await contribution in group {
            running += contribution
            continuation.yield(Money(running, currency))
          }
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// One provider's total contribution to a portfolio sum, converted into
  /// `currency`. Returns `0` (and logs) when the provider or an FX conversion
  /// fails, so one bad provider never sinks the live stream.
  private static func providerContribution(
    _ provider: any BrokerageProvider,
    in currency: CurrencyCode,
    fx: any FXService,
    asOf: Date,
    logger: Logger
  ) async -> Decimal {
    do {
      var sum = Decimal.zero
      let accounts = try await provider.listAccounts()
      for account in accounts {
        let balance = try await provider.balance(for: account.id)
        let converted = try await fx.convert(balance.total, to: currency, at: asOf)
        sum += converted.amount
      }
      return sum
    } catch {
      logger.error(
        "Provider \(provider.id.rawValue, privacy: .public) failed in live total; contributing 0"
      )
      return 0
    }
  }

  // MARK: Combined history

  /// Merges every account's portfolio-value history into one portfolio-wide
  /// series over `range`, expressed in `currency`.
  ///
  /// ## Approach
  /// 1. For each account (across all providers) the per-account series is
  ///    obtained from ``BrokerageProvider/portfolioHistory(accountID:range:)``
  ///    (the snapshot-reconstruction default extension).
  /// 2. The union of every series' timestamps forms the merged time axis,
  ///    sorted ascending.
  /// 3. At each merged timestamp every account is sampled with a nearest-prior
  ///    (last-observation-carried-forward) lookup — the account's most recent
  ///    point at or before the timestamp. Accounts with no point yet at that
  ///    timestamp contribute nothing (they have not started). Each sampled value
  ///    is FX-converted to `currency` and summed.
  /// 4. The result carries `subject = .portfolio(providerID: nil)` (aggregate
  ///    across all providers) and the range's recommended granularity.
  ///
  /// - Throws: Rethrows the first provider or FX error encountered.
  public func combinedHistory(
    range: TimeRange,
    in currency: CurrencyCode = .usd
  ) async throws -> PerformanceSeries {
    let accounts = try await allAccounts()
    let asOf = Date()

    // Pair each account with the provider that owns it so we can call its
    // reconstruction directly.
    var seriesByAccount: [(account: Account, points: [PerformanceSeries.Point])] = []
    for account in accounts {
      guard let provider = providers.first(where: { $0.id == account.providerID }) else {
        continue
      }
      let series = try await provider.portfolioHistory(accountID: account.id, range: range)
      let sorted = series.points.sorted { $0.timestamp < $1.timestamp }
      seriesByAccount.append((account, sorted))
    }

    // Build the merged, sorted, de-duplicated time axis.
    var timestampSet = Set<Date>()
    for entry in seriesByAccount {
      for point in entry.points {
        timestampSet.insert(point.timestamp)
      }
    }
    let timeline = timestampSet.sorted()

    // Sum FX-converted, carried-forward values at each merged timestamp.
    var merged: [PerformanceSeries.Point] = []
    merged.reserveCapacity(timeline.count)
    for timestamp in timeline {
      var sum = Decimal.zero
      for entry in seriesByAccount {
        guard let value = Self.nearestPriorValue(entry.points, at: timestamp) else {
          continue
        }
        let converted = try await fx.convert(value, to: currency, at: asOf)
        sum += converted.amount
      }
      merged.append(PerformanceSeries.Point(timestamp: timestamp, value: Money(sum, currency)))
    }

    return PerformanceSeries(
      subject: .portfolio(providerID: nil),
      range: range,
      points: merged,
      granularity: range.granularity
    )
  }

  /// The most recent point value at or before `timestamp`, or `nil` when every
  /// point is after it. `points` are assumed sorted oldest-first.
  private static func nearestPriorValue(
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
