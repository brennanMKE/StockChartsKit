import Foundation
import Testing

import StockChartsKit
import StockChartsKitTesting

@testable import StockChartsKitMarketData

/// Offline tests for the default market-data stack. Every request is served by
/// the HTTP-replay harness from a synthetic fixture; no live network or token
/// is involved.
@Suite("StockChartsKitMarketData (offline)")
struct StockChartsKitMarketDataTests {
  /// A scheme/host that does not resolve, proving responses come from fixtures.
  /// The provider builds its own absolute URLs against real hosts; the replay
  /// protocol claims the request regardless of host because it matches on the
  /// path, so nothing escapes to the network.
  private static let utcCalendar = InMemoryDailyBarCache.utcCalendar

  /// A fixed "now" just after the newest fixture bar (2024-01-04, a Thursday)
  /// so the daily cache considers that bar fresh.
  private static let fixedNow = Date(timeIntervalSince1970: 1_704_405_600)  // 2024-01-04 22:00 UTC

  private func now() -> Date { Self.fixedNow }

  /// A no-op retry wait, mirroring `HTTPClientTests`, so retries never touch a
  /// real clock (and avoid a toolchain `Task.sleep(.zero)` allocator quirk).
  private static let noSleep: @Sendable (Duration) async throws -> Void = { _ in }

  // MARK: Tiingo

  @Test("Tiingo daily price history maps to a daily PerformanceSeries")
  func tiingoPriceHistory() async throws {
    let store = FixtureStore()
    try store.register(
      key: FixtureKey(method: "GET", path: "/tiingo/daily/AMD/prices"),
      fixtureNamed: "tiingo-daily",
      in: Bundle.module
    )
    let session = ReplayURLProtocol.makeSession(store: store)
    defer { ReplayURLProtocol.deregister(session: session) }

    let tiingo = TiingoMarketData(
      apiKey: "test-token",
      session: session,
      retryPolicy: .immediate,
      sleep: Self.noSleep,
      now: { Self.fixedNow },
      calendar: Self.utcCalendar
    )
    let series = try await tiingo.priceHistory(
      symbol: Symbol(rawValue: "AMD"),
      range: .threeMonths
    )

    #expect(series.granularity == .oneDay)
    #expect(series.points.count == 3)
    #expect(series.points.first?.value.amount == Decimal(138.0))
    #expect(series.points.last?.value.amount == Decimal(string: "142.25"))
    // Points are ordered oldest to newest, so asOf is the last point.
    #expect(series.points.last?.timestamp ?? .distantPast > (series.points.first?.timestamp ?? .now))
  }

  @Test("Tiingo IEX quote maps to a Quote")
  func tiingoQuote() async throws {
    let store = FixtureStore()
    try store.register(
      key: FixtureKey(method: "GET", path: "/iex/AMD"),
      fixtureNamed: "tiingo-iex",
      in: Bundle.module
    )
    let session = ReplayURLProtocol.makeSession(store: store)
    defer { ReplayURLProtocol.deregister(session: session) }

    let tiingo = TiingoMarketData(
      apiKey: "test-token",
      session: session,
      retryPolicy: .immediate,
      sleep: Self.noSleep
    )
    let quote = try await tiingo.quote(symbol: Symbol(rawValue: "AMD"))

    #expect(quote.symbol == Symbol(rawValue: "AMD"))
    #expect(quote.last.amount == Decimal(string: "142.25"))
    #expect(quote.previousClose?.amount == Decimal(140.5))
  }

  // MARK: Yahoo

  @Test("Yahoo chart maps to a daily PerformanceSeries")
  func yahooPriceHistory() async throws {
    let store = FixtureStore()
    try store.register(
      key: FixtureKey(method: "GET", path: "/v8/finance/chart/AMD"),
      fixtureNamed: "yahoo-chart",
      in: Bundle.module
    )
    let session = ReplayURLProtocol.makeSession(store: store)
    defer { ReplayURLProtocol.deregister(session: session) }

    let yahoo = YahooFinanceMarketData(
      session: session,
      retryPolicy: .immediate,
      sleep: Self.noSleep
    )
    let series = try await yahoo.priceHistory(
      symbol: Symbol(rawValue: "AMD"),
      range: .threeMonths
    )

    #expect(series.granularity == .oneDay)
    #expect(series.points.count == 3)
    #expect(series.points.first?.value.amount == Decimal(138.0))
    #expect(series.points.last?.value.amount == Decimal(string: "142.25"))
    #expect(series.points.first?.value.currency == .usd)
  }

  @Test("Yahoo chart yields a Quote with last and previous close")
  func yahooQuote() async throws {
    let store = FixtureStore()
    try store.register(
      key: FixtureKey(method: "GET", path: "/v8/finance/chart/AMD"),
      fixtureNamed: "yahoo-chart",
      in: Bundle.module
    )
    let session = ReplayURLProtocol.makeSession(store: store)
    defer { ReplayURLProtocol.deregister(session: session) }

    let yahoo = YahooFinanceMarketData(
      session: session,
      retryPolicy: .immediate,
      sleep: Self.noSleep,
      now: now
    )
    let quote = try await yahoo.quote(symbol: Symbol(rawValue: "AMD"))

    #expect(quote.last.amount == Decimal(string: "142.25"))
    #expect(quote.previousClose?.amount == Decimal(136.0))
  }

  // MARK: Tiered fallback

  @Test("Tiered provider falls back to Yahoo when Tiingo fails")
  func tieredFallsBackOnPrimaryFailure() async throws {
    let store = FixtureStore()
    // Tiingo returns 500 (a non-retryable terminal failure after retries).
    store.register(
      key: FixtureKey(method: "GET", path: "/tiingo/daily/AMD/prices"),
      fixture: HTTPFixture(statusCode: 500, body: Data(#"{"detail":"boom"}"#.utf8))
    )
    // Yahoo serves the data.
    try store.register(
      key: FixtureKey(method: "GET", path: "/v8/finance/chart/AMD"),
      fixtureNamed: "yahoo-chart",
      in: Bundle.module
    )
    let session = ReplayURLProtocol.makeSession(store: store)
    defer { ReplayURLProtocol.deregister(session: session) }

    let tiered = TieredMarketDataProvider(
      primary: TiingoMarketData(
        apiKey: "test-token",
        session: session,
        retryPolicy: .immediate,
        sleep: Self.noSleep,
        now: now,
        calendar: Self.utcCalendar
      ),
      fallback: YahooFinanceMarketData(
        session: session,
        retryPolicy: .immediate,
        sleep: Self.noSleep,
        now: now
      ),
      cache: InMemoryDailyBarCache(calendar: Self.utcCalendar),
      now: now,
      calendar: Self.utcCalendar
    )
    let series = try await tiered.priceHistory(
      symbol: Symbol(rawValue: "AMD"),
      range: .threeMonths
    )

    // The result came from Yahoo: three points matching the Yahoo fixture.
    #expect(series.points.count == 3)
    #expect(series.points.last?.value.amount == Decimal(string: "142.25"))
    // Yahoo was actually hit.
    #expect(store.hitCount(for: FixtureKey(method: "GET", path: "/v8/finance/chart/AMD")) >= 1)
    // Tiingo was tried (and exhausted its retries).
    #expect(store.hitCount(for: FixtureKey(method: "GET", path: "/tiingo/daily/AMD/prices")) >= 1)
  }

  // MARK: Caching

  @Test("Daily request is served from cache without a second network hit")
  func dailyServedFromCacheOnSecondCall() async throws {
    let store = FixtureStore()
    try store.register(
      key: FixtureKey(method: "GET", path: "/tiingo/daily/AMD/prices"),
      fixtureNamed: "tiingo-daily",
      in: Bundle.module
    )
    let session = ReplayURLProtocol.makeSession(store: store)
    defer { ReplayURLProtocol.deregister(session: session) }

    let tiered = TieredMarketDataProvider(
      primary: TiingoMarketData(
        apiKey: "test-token",
        session: session,
        retryPolicy: .immediate,
        sleep: Self.noSleep,
        now: now,
        calendar: Self.utcCalendar
      ),
      fallback: YahooFinanceMarketData(
        session: session,
        retryPolicy: .immediate,
        sleep: Self.noSleep,
        now: now
      ),
      cache: InMemoryDailyBarCache(calendar: Self.utcCalendar),
      now: now,
      calendar: Self.utcCalendar
    )
    let symbol = Symbol(rawValue: "AMD")
    let dailyKey = FixtureKey(method: "GET", path: "/tiingo/daily/AMD/prices")

    let first = try await tiered.priceHistory(symbol: symbol, range: .threeMonths)
    #expect(first.points.count == 3)
    let hitsAfterFirst = store.hitCount(for: dailyKey)
    #expect(hitsAfterFirst == 1)

    let second = try await tiered.priceHistory(symbol: symbol, range: .threeMonths)
    #expect(second.points.count == 3)
    // Cache hit: no additional network request.
    #expect(store.hitCount(for: dailyKey) == hitsAfterFirst)
  }

  @Test("Intraday (1D) is fetched live each time and never cached")
  func intradayNotCached() async throws {
    let store = FixtureStore()
    // Yahoo answers the intraday chart; Tiingo has no intraday daily fixture so
    // it will fail and the tiered provider falls back to Yahoo for 1D.
    store.register(
      key: FixtureKey(method: "GET", path: "/iex/AMD"),
      fixture: HTTPFixture(statusCode: 500, body: Data("boom".utf8))
    )
    store.register(
      key: FixtureKey(method: "GET", path: "/tiingo/daily/AMD/prices"),
      fixture: HTTPFixture(statusCode: 500, body: Data("boom".utf8))
    )
    try store.register(
      key: FixtureKey(method: "GET", path: "/v8/finance/chart/AMD"),
      fixtureNamed: "yahoo-chart",
      in: Bundle.module
    )
    let session = ReplayURLProtocol.makeSession(store: store)
    defer { ReplayURLProtocol.deregister(session: session) }

    let tiered = TieredMarketDataProvider(
      primary: TiingoMarketData(
        apiKey: "test-token",
        session: session,
        retryPolicy: .immediate,
        sleep: Self.noSleep,
        now: now,
        calendar: Self.utcCalendar
      ),
      fallback: YahooFinanceMarketData(
        session: session,
        retryPolicy: .immediate,
        sleep: Self.noSleep,
        now: now
      ),
      cache: InMemoryDailyBarCache(calendar: Self.utcCalendar),
      now: now,
      calendar: Self.utcCalendar
    )
    let symbol = Symbol(rawValue: "AMD")
    let yahooKey = FixtureKey(method: "GET", path: "/v8/finance/chart/AMD")

    _ = try await tiered.priceHistory(symbol: symbol, range: .oneDay)
    let hitsAfterFirst = store.hitCount(for: yahooKey)
    #expect(hitsAfterFirst >= 1)

    _ = try await tiered.priceHistory(symbol: symbol, range: .oneDay)
    // Intraday is not cached: the second call hits the network again.
    #expect(store.hitCount(for: yahooKey) > hitsAfterFirst)
  }
}
