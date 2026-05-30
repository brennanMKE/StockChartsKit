import Foundation
import Testing

import StockChartsKit
import StockChartsKitTesting

@testable import StockChartsKitSchwab

/// Offline tests for the Schwab provider. Reads are served by the HTTP-replay
/// harness from synthetic, redacted fixtures; the auth flow runs against a
/// replayed token endpoint and an in-memory token store, so no live network or
/// real credential is ever involved.
@Suite("StockChartsKitSchwab (offline)")
struct StockChartsKitSchwabTests {
  /// A fixed "now" just after the newest candle (2024-01-04) so token-expiry and
  /// range math are deterministic.
  private static let fixedNow = Date(timeIntervalSince1970: 1_704_405_600)

  private static let noSleep: @Sendable (Duration) async throws -> Void = { _ in }

  /// Synthetic developer-app credentials. No real client ID or secret.
  private static func configuration() -> Configuration {
    Configuration(secrets: [
      "clientID": "synthetic-client-id",
      "clientSecret": "synthetic-client-secret",
      "redirectURI": "https://127.0.0.1/oauth/schwab",
    ])
  }

  /// Builds a provider whose token store is pre-seeded with a valid access
  /// token, so read methods run without the auth dance.
  private static func makeAuthenticatedProvider(
    session: URLSession,
    store: InMemoryTokenStore = InMemoryTokenStore()
  ) async throws -> SchwabProvider {
    let bundle = TokenBundle(
      accessToken: "REDACTED-SEEDED-ACCESS-TOKEN",
      refreshToken: "REDACTED-SEEDED-REFRESH-TOKEN",
      expiresAt: fixedNow.addingTimeInterval(3600)
    )
    let json = String(data: try JSONEncoder().encode(bundle), encoding: .utf8)!
    try await store.set(json, for: "schwab.schwab")
    return try SchwabProvider(
      configuration: configuration(),
      tokenStore: store,
      session: session,
      retryPolicy: .immediate,
      sleep: noSleep,
      now: { fixedNow },
      makeState: { "fixed-state-123" }
    )
  }

  // MARK: Reads

  @Test("listAccounts surfaces the hashed key as the AccountID")
  func listAccounts() async throws {
    let store = FixtureStore()
    try store.register(
      key: FixtureKey(method: "GET", path: "/trader/v1/accounts/accountNumbers"),
      fixtureNamed: "accountNumbers",
      in: Bundle.module
    )
    try store.register(
      key: FixtureKey(method: "GET", path: "/trader/v1/accounts"),
      fixtureNamed: "accounts",
      in: Bundle.module
    )
    let session = ReplayURLProtocol.makeSession(store: store)
    defer { ReplayURLProtocol.deregister(session: session) }

    let provider = try await Self.makeAuthenticatedProvider(session: session)
    let accounts = try await provider.listAccounts()

    #expect(accounts.count == 2)
    // The AccountID is the hashed key, not the visible number — so per-account
    // paths work directly (mirrors E*Trade's accountIdKey).
    #expect(accounts.contains { $0.id == AccountID(rawValue: "REDACTEDHASH0001") })
    #expect(accounts.contains { $0.id == AccountID(rawValue: "REDACTEDHASH0002") })
    let margin = try #require(accounts.first { $0.id == AccountID(rawValue: "REDACTEDHASH0001") })
    #expect(margin.kind == .margin)
    #expect(margin.displayName == "Schwab 00099991")
    #expect(accounts.allSatisfy { $0.baseCurrency == .usd })
  }

  @Test("positions maps instruments to Positions with Decimal quantities and assetClass")
  func positions() async throws {
    let store = FixtureStore()
    try store.register(
      key: FixtureKey(method: "GET", path: "/trader/v1/accounts/REDACTEDHASH0001"),
      fixtureNamed: "accountDetail",
      in: Bundle.module
    )
    let session = ReplayURLProtocol.makeSession(store: store)
    defer { ReplayURLProtocol.deregister(session: session) }

    let provider = try await Self.makeAuthenticatedProvider(session: session)
    let positions = try await provider.positions(
      for: AccountID(rawValue: "REDACTEDHASH0001")
    )

    #expect(positions.count == 2)
    let amd = try #require(positions.first { $0.symbol == Symbol(rawValue: "AMD") })
    #expect(amd.assetClass == .equity)
    #expect(amd.quantity == Decimal(string: "100"))
    #expect(amd.marketValue.amount == Decimal(string: "12500.00"))
    #expect(amd.averageCost?.amount == Decimal(string: "95.40"))
    let voo = try #require(positions.first { $0.symbol == Symbol(rawValue: "VOO") })
    #expect(voo.assetClass == .etf)
    #expect(voo.quantity == Decimal(string: "12.5"))
  }

  @Test("balance reads currentBalances into a Balance")
  func balance() async throws {
    let store = FixtureStore()
    try store.register(
      key: FixtureKey(method: "GET", path: "/trader/v1/accounts/REDACTEDHASH0001"),
      fixtureNamed: "accountDetail",
      in: Bundle.module
    )
    let session = ReplayURLProtocol.makeSession(store: store)
    defer { ReplayURLProtocol.deregister(session: session) }

    let provider = try await Self.makeAuthenticatedProvider(session: session)
    let balance = try await provider.balance(
      for: AccountID(rawValue: "REDACTEDHASH0001")
    )

    #expect(balance.total.amount == Decimal(string: "125000.50"))
    #expect(balance.cash.amount == Decimal(string: "5000.25"))
    #expect(balance.buyingPower?.amount == Decimal(string: "9600.00"))
    #expect(balance.total.currency == .usd)
  }

  @Test("quote maps the symbol-keyed quote entry to a Quote")
  func quote() async throws {
    let store = FixtureStore()
    try store.register(
      key: FixtureKey(method: "GET", path: "/marketdata/v1/quotes"),
      fixtureNamed: "quote",
      in: Bundle.module
    )
    let session = ReplayURLProtocol.makeSession(store: store)
    defer { ReplayURLProtocol.deregister(session: session) }

    let provider = try await Self.makeAuthenticatedProvider(session: session)
    let quote = try await provider.quote(for: Symbol(rawValue: "AMD"))

    #expect(quote.symbol == Symbol(rawValue: "AMD"))
    #expect(quote.last.amount == Decimal(string: "128.45"))
    #expect(quote.previousClose?.amount == Decimal(string: "125.10"))
  }

  // MARK: Native price history (the distinguishing capability)

  @Test("priceHistory maps native candles to a PerformanceSeries of Decimal closes")
  func priceHistory() async throws {
    let store = FixtureStore()
    try store.register(
      key: FixtureKey(method: "GET", path: "/marketdata/v1/pricehistory"),
      fixtureNamed: "pricehistory",
      in: Bundle.module
    )
    let session = ReplayURLProtocol.makeSession(store: store)
    defer { ReplayURLProtocol.deregister(session: session) }

    let provider = try await Self.makeAuthenticatedProvider(session: session)
    let series = try await provider.priceHistory(
      symbol: Symbol(rawValue: "AMD"),
      range: .oneMonth
    )

    // .oneMonth maps to a daily granularity.
    #expect(series.granularity == .oneDay)
    #expect(series.subject == .symbol(Symbol(rawValue: "AMD")))
    #expect(series.points.count == 3)
    // Points are ordered oldest to newest and carry the candle close as Decimal.
    #expect(series.points.first?.value.amount == Decimal(string: "121.75"))
    #expect(series.points.last?.value.amount == Decimal(string: "128.45"))
    #expect((series.points.first?.timestamp ?? .now) < (series.points.last?.timestamp ?? .distantPast))
    // Schwab datetime is epoch ms; confirm conversion to the first candle date.
    #expect(series.points.first?.timestamp == Date(timeIntervalSince1970: 1_704_153_600))
    #expect(store.hitCount(for: FixtureKey(method: "GET", path: "/marketdata/v1/pricehistory")) == 1)
  }

  @Test("capabilities advertise native price history")
  func capabilitiesIncludeNativeHistory() async throws {
    let provider = try SchwabProvider(
      configuration: Self.configuration(),
      tokenStore: InMemoryTokenStore()
    )
    #expect(provider.capabilities.contains(.nativePriceHistory))
    #expect(provider.capabilities.contains(.positions))
    #expect(provider.capabilities.contains(.balances))
    #expect(provider.capabilities.contains(.quotes))
  }

  // MARK: TimeRange -> pricehistory parameter mapping

  @Test("TimeRange maps to Schwab pricehistory parameters")
  func priceHistoryParameterMapping() {
    func params(_ range: TimeRange) -> SchwabProvider.PriceHistoryParameters {
      SchwabProvider.priceHistoryParameters(for: range)
    }
    #expect(params(.oneDay) == .init(periodType: "day", period: 1, frequencyType: "minute", frequency: 1))
    #expect(params(.oneWeek) == .init(periodType: "day", period: 5, frequencyType: "minute", frequency: 30))
    #expect(params(.oneMonth) == .init(periodType: "month", period: 1, frequencyType: "daily", frequency: 1))
    #expect(params(.threeMonths) == .init(periodType: "month", period: 3, frequencyType: "daily", frequency: 1))
    #expect(params(.yearToDate) == .init(periodType: "ytd", period: 1, frequencyType: "daily", frequency: 1))
    #expect(params(.oneYear) == .init(periodType: "year", period: 1, frequencyType: "daily", frequency: 1))
    #expect(params(.fiveYears) == .init(periodType: "year", period: 5, frequencyType: "weekly", frequency: 1))
    #expect(params(.max) == .init(periodType: "year", period: 20, frequencyType: "monthly", frequency: 1))
  }

  // MARK: Authentication (no live network)

  @Test("authorization URL carries response_type, client_id, redirect_uri, scope and state")
  func authorizationURL() async throws {
    let provider = try SchwabProvider(
      configuration: Self.configuration(),
      tokenStore: InMemoryTokenStore(),
      now: { Self.fixedNow },
      makeState: { "fixed-state-123" }
    )
    let session = try await provider.authenticate() as? SchwabAuthSession
    let auth = try #require(session)

    let url = await provider.authorizationURL(state: auth.state)
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

    #expect(value("response_type") == "code")
    #expect(value("client_id") == "synthetic-client-id")
    #expect(value("redirect_uri") == "https://127.0.0.1/oauth/schwab")
    #expect(value("scope") == "readonly")
    #expect(value("state") == "fixed-state-123")
  }

  @Test("the token-exchange request carries the correct Basic auth header")
  func basicAuthHeader() {
    // base64("synthetic-client-id:synthetic-client-secret") computed independently.
    let expected = "Basic "
      + Data("synthetic-client-id:synthetic-client-secret".utf8).base64EncodedString()
    #expect(
      SchwabProvider.basicAuthHeader(
        clientID: "synthetic-client-id",
        clientSecret: "synthetic-client-secret"
      ) == expected
    )

    let request = SchwabProvider.tokenRequest(
      endpoint: SchwabProvider.tokenEndpoint,
      fields: ["grant_type": "authorization_code", "code": "abc"],
      clientID: "synthetic-client-id",
      clientSecret: "synthetic-client-secret"
    )
    let header = request?.value(forHTTPHeaderField: "Authorization")
    #expect(header == expected)
    #expect(request?.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
  }

  @Test("token exchange stores a token and flips authenticationStatus to .connected")
  func tokenExchangeConnects() async throws {
    let store = FixtureStore()
    try store.register(
      key: FixtureKey(method: "POST", path: "/v1/oauth/token"),
      fixtureNamed: "token",
      in: Bundle.module
    )
    let session = ReplayURLProtocol.makeSession(store: store)
    defer { ReplayURLProtocol.deregister(session: session) }

    let tokenStore = InMemoryTokenStore()
    let provider = try SchwabProvider(
      configuration: Self.configuration(),
      tokenStore: tokenStore,
      session: session,
      retryPolicy: .immediate,
      sleep: Self.noSleep,
      now: { Self.fixedNow },
      makeState: { "fixed-state-123" }
    )

    // Before auth: a challenge is required.
    let before = await provider.authenticationStatus()
    guard case .requiresChallenge(.oauthRedirect) = before else {
      Issue.record("Expected requiresChallenge before auth, got \(before)")
      return
    }

    let auth = try await provider.authenticate()
    var callback = URLComponents(string: "https://127.0.0.1/oauth/schwab")!
    callback.queryItems = [
      URLQueryItem(name: "code", value: "synthetic-auth-code"),
      URLQueryItem(name: "state", value: "fixed-state-123"),
    ]
    try await auth.complete(callbackURL: callback.url!)

    // A token was stored (the seeded synthetic value).
    let stored = try await tokenStore.secret("schwab.schwab")
    #expect(stored.contains("REDACTED-SYNTHETIC-ACCESS-TOKEN"))

    // After auth: connected.
    let after = await provider.authenticationStatus()
    guard case .connected(let connectionID) = after else {
      Issue.record("Expected connected after auth, got \(after)")
      return
    }
    #expect(connectionID == ConnectionID(rawValue: "schwab"))
    #expect(store.hitCount(for: FixtureKey(method: "POST", path: "/v1/oauth/token")) == 1)
  }

  @Test("token exchange rejects a mismatched OAuth state")
  func stateMismatchRejected() async throws {
    let provider = try SchwabProvider(
      configuration: Self.configuration(),
      tokenStore: InMemoryTokenStore(),
      makeState: { "expected-state" }
    )
    let auth = try await provider.authenticate()
    var callback = URLComponents(string: "https://127.0.0.1/oauth/schwab")!
    callback.queryItems = [
      URLQueryItem(name: "code", value: "synthetic-auth-code"),
      URLQueryItem(name: "state", value: "ATTACKER-STATE"),
    ]
    await #expect(throws: BrokerageError.self) {
      try await auth.complete(callbackURL: callback.url!)
    }
  }

  @Test("an expired access token is transparently refreshed before a read")
  func refreshPath() async throws {
    let store = FixtureStore()
    // The refresh hits the token endpoint, then the read hits the quote endpoint.
    try store.register(
      key: FixtureKey(method: "POST", path: "/v1/oauth/token"),
      fixtureNamed: "refresh",
      in: Bundle.module
    )
    try store.register(
      key: FixtureKey(method: "GET", path: "/marketdata/v1/quotes"),
      fixtureNamed: "quote",
      in: Bundle.module
    )
    let session = ReplayURLProtocol.makeSession(store: store)
    defer { ReplayURLProtocol.deregister(session: session) }

    let tokenStore = InMemoryTokenStore()
    // Seed an already-expired access token with a usable refresh token.
    let bundle = TokenBundle(
      accessToken: "REDACTED-STALE-ACCESS-TOKEN",
      refreshToken: "REDACTED-SEEDED-REFRESH-TOKEN",
      expiresAt: Self.fixedNow.addingTimeInterval(-10)
    )
    let json = String(data: try JSONEncoder().encode(bundle), encoding: .utf8)!
    try await tokenStore.set(json, for: "schwab.schwab")

    let provider = try SchwabProvider(
      configuration: Self.configuration(),
      tokenStore: tokenStore,
      session: session,
      retryPolicy: .immediate,
      sleep: Self.noSleep,
      now: { Self.fixedNow },
      makeState: { "fixed-state-123" }
    )

    // A read succeeds, which requires the signer to have refreshed first.
    let quote = try await provider.quote(for: Symbol(rawValue: "AMD"))
    #expect(quote.last.amount == Decimal(string: "128.45"))

    // The refresh was performed and persisted the rotated access token.
    #expect(store.hitCount(for: FixtureKey(method: "POST", path: "/v1/oauth/token")) == 1)
    let stored = try await tokenStore.secret("schwab.schwab")
    #expect(stored.contains("REDACTED-SYNTHETIC-REFRESHED-ACCESS-TOKEN"))
  }
}

/// An in-memory ``TokenStore`` for offline tests, standing in for the Keychain
/// (which is unavailable under `swift test`).
actor InMemoryTokenStore: TokenStore {
  private var items: [String: String] = [:]

  func secret(_ key: String) async throws -> String {
    guard let value = items[key] else { throw BrokerageError.notAuthenticated }
    return value
  }

  func set(_ value: String, for key: String) async throws {
    items[key] = value
  }

  func delete(_ key: String) async throws {
    items[key] = nil
  }
}
