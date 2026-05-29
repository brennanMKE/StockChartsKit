import Foundation
import Testing

@testable import StockChartsKit
import StockChartsKitTesting

@Suite("ECBFXService (offline)")
struct FXServiceTests {
  private let date = Date(timeIntervalSince1970: 1_780_000_000)

  /// Builds a service backed by a replay session seeded with the given fixtures.
  private func makeService(store: FixtureStore) -> (ECBFXService, URLSession) {
    let session = ReplayURLProtocol.makeSession(store: store)
    let service = ECBFXService(
      session: session,
      now: { Date(timeIntervalSince1970: 1_780_000_000) }
    )
    return (service, session)
  }

  private func ecbStore() throws -> FixtureStore {
    let store = FixtureStore()
    try store.register(
      key: FixtureKey(method: "GET", path: "/stats/eurofxref/eurofxref-daily.xml"),
      fixtureNamed: "ecb-daily",
      in: Bundle.module
    )
    return store
  }

  @Test("same currency returns a rate of 1")
  func sameCurrency() async throws {
    let (service, session) = makeService(store: FixtureStore())
    defer { ReplayURLProtocol.deregister(session: session) }
    let rate = try await service.rate(from: .usd, to: .usd, at: date)
    #expect(rate == 1)
  }

  @Test("EUR base rate is read straight from the ECB table")
  func eurToUSD() async throws {
    let store = try ecbStore()
    let (service, session) = makeService(store: store)
    defer { ReplayURLProtocol.deregister(session: session) }
    let rate = try await service.rate(
      from: CurrencyCode(rawValue: "EUR"),
      to: .usd,
      at: date
    )
    // EUR -> USD is the table value directly.
    #expect(rate == Decimal(string: "1.0800"))
  }

  @Test("fiat cross rate is computed through EUR")
  func usdToGBPCrossRate() async throws {
    let store = try ecbStore()
    let (service, session) = makeService(store: store)
    defer { ReplayURLProtocol.deregister(session: session) }
    let rate = try await service.rate(from: .usd, to: CurrencyCode(rawValue: "GBP"), at: date)
    // USD -> GBP = (EUR -> GBP) / (EUR -> USD) = 0.85 / 1.08.
    let expected = Decimal(string: "0.8500")! / Decimal(string: "1.0800")!
    #expect(rate == expected)
  }

  @Test("inverse fiat rate divides into EUR correctly")
  func usdToEUR() async throws {
    let store = try ecbStore()
    let (service, session) = makeService(store: store)
    defer { ReplayURLProtocol.deregister(session: session) }
    let rate = try await service.rate(
      from: .usd,
      to: CurrencyCode(rawValue: "EUR"),
      at: date
    )
    // USD -> EUR = 1 / (EUR -> USD) = 1 / 1.08.
    let expected = Decimal(1) / Decimal(string: "1.0800")!
    #expect(rate == expected)
  }

  @Test("crypto falls back to the Coinbase spot endpoint")
  func btcToUSDViaCoinbase() async throws {
    let store = try ecbStore()
    try store.register(
      key: FixtureKey(method: "GET", path: "/v2/prices/BTC-USD/spot"),
      fixtureNamed: "coinbase-btc-usd-spot",
      in: Bundle.module
    )
    let (service, session) = makeService(store: store)
    defer { ReplayURLProtocol.deregister(session: session) }
    let rate = try await service.rate(
      from: CurrencyCode(rawValue: "BTC"),
      to: .usd,
      at: date
    )
    // BTC is absent from the ECB table, so the spot amount is used directly.
    #expect(rate == Decimal(string: "65000.00"))
  }

  @Test("convert applies the cross rate to a Money amount")
  func convertMoney() async throws {
    let store = try ecbStore()
    let (service, session) = makeService(store: store)
    defer { ReplayURLProtocol.deregister(session: session) }
    let result = try await service.convert(
      Money(100, .usd),
      to: CurrencyCode(rawValue: "GBP"),
      at: date
    )
    let expected = Decimal(100) * (Decimal(string: "0.8500")! / Decimal(string: "1.0800")!)
    #expect(result.currency == CurrencyCode(rawValue: "GBP"))
    #expect(result.amount == expected)
  }

  @Test("XML parsing yields one EUR-based factor per Cube element")
  func parseECBXML() throws {
    let url = try #require(
      Bundle.module.url(forResource: "ecb-daily", withExtension: "json", subdirectory: "Fixtures")
        ?? Bundle.module.url(forResource: "ecb-daily", withExtension: "json")
    )
    let fixtureData = try Data(contentsOf: url)
    let fixture = try JSONDecoder().decode(HTTPFixture.self, from: fixtureData)
    let table = try ECBFXService.parseECBXML(fixture.body)
    #expect(table[.usd] == Decimal(string: "1.0800"))
    #expect(table[CurrencyCode(rawValue: "GBP")] == Decimal(string: "0.8500"))
    #expect(table[CurrencyCode(rawValue: "CHF")] == Decimal(string: "0.9700"))
    #expect(table.count == 4)
  }
}
