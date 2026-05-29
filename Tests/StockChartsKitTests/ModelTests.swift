import Foundation
import Testing

@testable import StockChartsKit

@Suite("PerformanceSeries.summary")
struct PerformanceSeriesSummaryTests {
  private func series(_ values: [Decimal]) -> PerformanceSeries {
    let base = Date(timeIntervalSince1970: 0)
    let points = values.enumerated().map { index, value in
      PerformanceSeries.Point(
        timestamp: base.addingTimeInterval(Double(index) * 86400),
        value: .usd(value)
      )
    }
    return PerformanceSeries(
      subject: .symbol(Symbol(rawValue: "AMD")),
      range: .threeMonths,
      points: points,
      granularity: .oneDay
    )
  }

  @Test("empty points produce a nil summary")
  func emptyPointsNilSummary() {
    #expect(series([]).summary == nil)
  }

  @Test("zero start value produces a nil percentChange")
  func zeroStartNilPercent() throws {
    let summary = try #require(series([0, 50, 100]).summary)
    #expect(summary.percentChange == nil)
    #expect(summary.start.amount == 0)
    #expect(summary.end.amount == 100)
    #expect(summary.absoluteChange.amount == 100)
  }

  @Test("normal case matches the +290.85 (+145.35%) header math")
  func normalCase() throws {
    // start 200.10 -> end 490.95 => +290.85, +145.3523...%
    let start = Decimal(string: "200.10")!
    let end = Decimal(string: "490.95")!
    let summary = try #require(series([start, Decimal(300), end]).summary)
    #expect(summary.start.amount == start)
    #expect(summary.end.amount == end)
    #expect(summary.absoluteChange.amount == Decimal(string: "290.85")!)
    let pct = try #require(summary.percentChange)
    // 290.85 / 200.10 = 1.4535232...; verify it rounds to 1.4535.
    var rounded = Decimal()
    var raw = pct
    NSDecimalRound(&rounded, &raw, 4, .plain)
    #expect(rounded == Decimal(string: "1.4535")!)
    #expect(summary.absoluteChange.currency == .usd)
  }

  @Test("single point has start == end and zero change")
  func singlePoint() throws {
    let summary = try #require(series([Decimal(42)]).summary)
    #expect(summary.start.amount == 42)
    #expect(summary.end.amount == 42)
    #expect(summary.absoluteChange.amount == 0)
    #expect(summary.percentChange == 0)
  }
}

@Suite("Model Codable round-trips")
struct ModelCodableTests {
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  private func roundTrip<T: Codable & Equatable>(_ value: T) throws {
    let data = try encoder.encode(value)
    #expect(try decoder.decode(T.self, from: data) == value)
  }

  @Test("Account round-trips")
  func account() throws {
    try roundTrip(
      Account(
        id: AccountID(rawValue: "acct-1"),
        providerID: ProviderID(rawValue: "etrade"),
        displayName: "E*Trade Brokerage 1234",
        kind: .brokerage,
        baseCurrency: .usd,
        connectionID: ConnectionID(rawValue: "conn-1")
      )
    )
    // nil connectionID also round-trips.
    try roundTrip(
      Account(
        id: AccountID(rawValue: "acct-2"),
        providerID: ProviderID(rawValue: "coinbase"),
        displayName: "Coinbase",
        kind: .crypto,
        baseCurrency: CurrencyCode(rawValue: "USD"),
        connectionID: nil
      )
    )
  }

  @Test("Position round-trips")
  func position() throws {
    try roundTrip(
      Position(
        accountID: AccountID(rawValue: "acct-1"),
        symbol: Symbol(rawValue: "AMD"),
        assetClass: .equity,
        quantity: Decimal(string: "12.5")!,
        averageCost: .usd(Decimal(string: "100.25")!),
        marketValue: .usd(Decimal(string: "6134.375")!),
        unrealizedPL: nil,
        asOf: Date(timeIntervalSince1970: 1_700_000_000)
      )
    )
  }

  @Test("Balance round-trips")
  func balance() throws {
    try roundTrip(
      Balance(
        accountID: AccountID(rawValue: "acct-1"),
        total: .usd(1000),
        cash: .usd(250),
        buyingPower: .usd(500),
        asOf: Date(timeIntervalSince1970: 1_700_000_000)
      )
    )
  }

  @Test("Quote round-trips")
  func quote() throws {
    try roundTrip(
      Quote(
        symbol: Symbol(rawValue: "BTC-USD"),
        last: Money(Decimal(string: "65000.12")!, CurrencyCode(rawValue: "USD")),
        previousClose: nil,
        asOf: Date(timeIntervalSince1970: 1_700_000_000)
      )
    )
  }

  @Test("PerformanceSeries round-trips with all subject kinds")
  func performanceSeries() throws {
    let base = Date(timeIntervalSince1970: 0)
    let points = [
      PerformanceSeries.Point(timestamp: base, value: .usd(100)),
      PerformanceSeries.Point(timestamp: base.addingTimeInterval(86400), value: .usd(110)),
    ]
    try roundTrip(
      PerformanceSeries(
        subject: .symbol(Symbol(rawValue: "AMD")),
        range: .threeMonths, points: points, granularity: .oneDay
      )
    )
    try roundTrip(
      PerformanceSeries(
        subject: .account(AccountID(rawValue: "acct-1")),
        range: .oneYear, points: points, granularity: .oneDay
      )
    )
    try roundTrip(
      PerformanceSeries(
        subject: .portfolio(providerID: nil),
        range: .max, points: [], granularity: .oneWeek
      )
    )
  }
}
