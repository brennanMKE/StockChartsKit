import Foundation
import Testing

@testable import StockChartsKit
import StockChartsKitTesting

/// A deterministic ``FXService`` returning fixed rates, so aggregator tests do
/// not depend on the ECB/Coinbase network.
private struct StubFXService: FXService {
  /// `from -> to` rates keyed by an "FROM->TO" string. Same-currency is 1.
  let rates: [String: Decimal]

  func rate(from: CurrencyCode, to: CurrencyCode, at date: Date) async throws -> Decimal {
    if from == to { return 1 }
    let key = "\(from.rawValue)->\(to.rawValue)"
    guard let rate = rates[key] else {
      throw BrokerageError.currencyMismatch(lhs: from, rhs: to)
    }
    return rate
  }
}

@Suite("PortfolioAggregator")
struct PortfolioAggregatorTests {
  private let usd = CurrencyCode.usd
  private let eur = CurrencyCode(rawValue: "EUR")

  private func account(
    _ id: String,
    provider: ProviderID,
    currency: CurrencyCode
  ) -> Account {
    Account(
      id: AccountID(rawValue: id),
      providerID: provider,
      displayName: id,
      kind: .brokerage,
      baseCurrency: currency,
      connectionID: nil
    )
  }

  private func balance(_ accountID: AccountID, total: Money) -> Balance {
    Balance(
      accountID: accountID,
      total: total,
      cash: .usd(0),
      buyingPower: nil,
      asOf: .now
    )
  }

  // MARK: allAccounts

  @Test("allAccounts unions accounts across providers")
  func unionsAccounts() async throws {
    let pA = ProviderID(rawValue: "a")
    let pB = ProviderID(rawValue: "b")
    let mockA = MockBrokerageProvider(id: pA)
    let mockB = MockBrokerageProvider(id: pB)
    await mockA.setAccounts([account("a1", provider: pA, currency: usd)])
    await mockB.setAccounts([
      account("b1", provider: pB, currency: eur),
      account("b2", provider: pB, currency: eur),
    ])
    let aggregator = PortfolioAggregator(
      providers: [mockA, mockB],
      snapshotStore: InMemorySnapshotStore(),
      marketData: FixedMarketDataProvider(),
      fx: StubFXService(rates: [:])
    )
    let accounts = try await aggregator.allAccounts()
    #expect(accounts.count == 3)
    #expect(accounts.map(\.id.rawValue) == ["a1", "b1", "b2"])
  }

  // MARK: totalValue

  @Test("totalValue converts across two currencies via the stub FX")
  func totalConvertsCurrencies() async throws {
    let pA = ProviderID(rawValue: "usdco")
    let pB = ProviderID(rawValue: "eurco")
    let mockA = MockBrokerageProvider(id: pA)
    let mockB = MockBrokerageProvider(id: pB)
    let a1 = account("a1", provider: pA, currency: usd)
    let b1 = account("b1", provider: pB, currency: eur)
    await mockA.setAccounts([a1])
    await mockB.setAccounts([b1])
    await mockA.setBalance { _ in self.balance(a1.id, total: Money(1000, self.usd)) }
    await mockB.setBalance { _ in self.balance(b1.id, total: Money(500, self.eur)) }

    // EUR -> USD = 1.10.
    let fx = StubFXService(rates: ["EUR->USD": Decimal(string: "1.10")!])
    let aggregator = PortfolioAggregator(
      providers: [mockA, mockB],
      snapshotStore: InMemorySnapshotStore(),
      marketData: FixedMarketDataProvider(),
      fx: fx
    )
    let total = try await aggregator.totalValue(in: usd)
    // 1000 USD + 500 EUR * 1.10 = 1000 + 550 = 1550 USD.
    #expect(total.currency == usd)
    #expect(total.amount == Decimal(1550))
  }

  // MARK: liveTotalValues

  @Test("liveTotalValues emits incremental cumulative totals then finishes")
  func liveEmitsIncrementally() async throws {
    let pA = ProviderID(rawValue: "a")
    let pB = ProviderID(rawValue: "b")
    let mockA = MockBrokerageProvider(id: pA)
    let mockB = MockBrokerageProvider(id: pB)
    let a1 = account("a1", provider: pA, currency: usd)
    let b1 = account("b1", provider: pB, currency: usd)
    await mockA.setAccounts([a1])
    await mockB.setAccounts([b1])
    await mockA.setBalance { _ in self.balance(a1.id, total: Money(1000, self.usd)) }
    await mockB.setBalance { _ in self.balance(b1.id, total: Money(250, self.usd)) }

    let aggregator = PortfolioAggregator(
      providers: [mockA, mockB],
      snapshotStore: InMemorySnapshotStore(),
      marketData: FixedMarketDataProvider(),
      fx: StubFXService(rates: [:])
    )

    var emitted: [Decimal] = []
    for try await money in aggregator.liveTotalValues(in: usd) {
      emitted.append(money.amount)
    }
    // Two providers => two emissions; order of completion is nondeterministic,
    // but the cumulative series is monotonic and the final total is the sum.
    #expect(emitted.count == 2)
    #expect(emitted.last == Decimal(1250))
    #expect(emitted[0] < emitted[1])
  }

  @Test("liveTotalValues survives a failing provider, keeping others")
  func liveSurvivesFailure() async throws {
    let pGood = ProviderID(rawValue: "good")
    let pBad = ProviderID(rawValue: "bad")
    let good = MockBrokerageProvider(id: pGood)
    let bad = MockBrokerageProvider(id: pBad)
    let g1 = account("g1", provider: pGood, currency: usd)
    await good.setAccounts([g1])
    await good.setBalance { _ in self.balance(g1.id, total: Money(800, self.usd)) }
    await bad.setListAccounts { throw BrokerageError.notAuthenticated }

    let aggregator = PortfolioAggregator(
      providers: [good, bad],
      snapshotStore: InMemorySnapshotStore(),
      marketData: FixedMarketDataProvider(),
      fx: StubFXService(rates: [:])
    )

    var emitted: [Decimal] = []
    for try await money in aggregator.liveTotalValues(in: usd) {
      emitted.append(money.amount)
    }
    // The failing provider contributes 0; the good provider's value survives.
    #expect(emitted.count == 2)
    #expect(emitted.last == Decimal(800))
  }

  // MARK: combinedHistory

  @Test("combinedHistory aligns timestamps and sums converted values")
  func combinedHistoryAligns() async throws {
    let pA = ProviderID(rawValue: "a")
    let pB = ProviderID(rawValue: "b")
    let mockA = MockBrokerageProvider(id: pA)
    let mockB = MockBrokerageProvider(id: pB)
    let a1 = account("a1", provider: pA, currency: usd)
    let b1 = account("b1", provider: pB, currency: eur)
    await mockA.setAccounts([a1])
    await mockB.setAccounts([b1])

    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let t1 = Date(timeIntervalSince1970: 2_000_000)
    let t2 = Date(timeIntervalSince1970: 3_000_000)

    // Account A reports points at t0 and t2 (USD).
    await mockA.setPortfolioHistory { _, range in
      PerformanceSeries(
        subject: .account(a1.id),
        range: range,
        points: [
          PerformanceSeries.Point(timestamp: t0, value: Money(100, self.usd)),
          PerformanceSeries.Point(timestamp: t2, value: Money(120, self.usd)),
        ],
        granularity: range.granularity
      )
    }
    // Account B reports a single point at t1 (EUR).
    await mockB.setPortfolioHistory { _, range in
      PerformanceSeries(
        subject: .account(b1.id),
        range: range,
        points: [
          PerformanceSeries.Point(timestamp: t1, value: Money(50, self.eur))
        ],
        granularity: range.granularity
      )
    }

    // EUR -> USD = 2.0 keeps the arithmetic obvious.
    let fx = StubFXService(rates: ["EUR->USD": Decimal(2)])
    let aggregator = PortfolioAggregator(
      providers: [mockA, mockB],
      snapshotStore: InMemorySnapshotStore(),
      marketData: FixedMarketDataProvider(),
      fx: fx
    )

    let series = try await aggregator.combinedHistory(range: .oneMonth, in: usd)
    #expect(series.subject == .portfolio(providerID: nil))
    // Merged timeline is the union {t0, t1, t2}.
    #expect(series.points.map(\.timestamp) == [t0, t1, t2])
    // t0: A=100, B not started -> 100.
    #expect(series.points[0].value.amount == Decimal(100))
    // t1: A carried 100, B=50 EUR * 2 = 100 -> 200.
    #expect(series.points[1].value.amount == Decimal(200))
    // t2: A=120, B carried 50 EUR * 2 = 100 -> 220.
    #expect(series.points[2].value.amount == Decimal(220))
  }
}
