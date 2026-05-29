import CryptoKit
import Foundation
import Testing

import StockChartsKit
import StockChartsKitTesting

@testable import StockChartsKitCoinbase

/// Offline tests for the Coinbase provider. Reads are served by the HTTP-replay
/// harness from synthetic, redacted fixtures; the auth flow runs against a
/// replayed token endpoint and an in-memory token store, so no live network or
/// real credential is ever involved.
@Suite("StockChartsKitCoinbase (offline)")
struct StockChartsKitCoinbaseTests {
  /// A fixed "now" just after the newest candle (2024-01-04) so token-expiry and
  /// range math are deterministic.
  private static let fixedNow = Date(timeIntervalSince1970: 1_704_405_600)

  private static let noSleep: @Sendable (Duration) async throws -> Void = { _ in }

  /// Synthetic developer-app credentials. No real client ID or secret — and
  /// crucially, no secret at all (Coinbase is PKCE-only).
  private static func configuration() -> Configuration {
    Configuration(secrets: [
      "clientID": "synthetic-client-id",
      "redirectURI": "stockcharts://oauth/coinbase",
    ])
  }

  /// Builds a provider whose token store is pre-seeded with a valid access
  /// token, so read methods run without the auth dance.
  private static func makeAuthenticatedProvider(
    session: URLSession,
    store: InMemoryTokenStore = InMemoryTokenStore()
  ) async throws -> CoinbaseProvider {
    let bundle = TokenBundle(
      accessToken: "REDACTED-SEEDED-ACCESS-TOKEN",
      refreshToken: "REDACTED-SEEDED-REFRESH-TOKEN",
      expiresAt: fixedNow.addingTimeInterval(3600)
    )
    let json = String(data: try JSONEncoder().encode(bundle), encoding: .utf8)!
    try await store.set(json, for: "coinbase.coinbase")
    return try CoinbaseProvider(
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

  @Test("listAccounts maps the accounts envelope to [Account]")
  func listAccounts() async throws {
    let store = FixtureStore()
    try store.register(
      key: FixtureKey(method: "GET", path: "/api/v3/brokerage/accounts"),
      fixtureNamed: "accounts",
      in: Bundle.module
    )
    let session = ReplayURLProtocol.makeSession(store: store)
    defer { ReplayURLProtocol.deregister(session: session) }

    let provider = try await Self.makeAuthenticatedProvider(session: session)
    let accounts = try await provider.listAccounts()

    #expect(accounts.count == 3)
    #expect(accounts.allSatisfy { $0.kind == .crypto })
    #expect(accounts.contains { $0.baseCurrency == CurrencyCode(rawValue: "BTC") })
    #expect(store.hitCount(for: FixtureKey(method: "GET", path: "/api/v3/brokerage/accounts")) == 1)
  }

  @Test("positions maps only non-zero balances to .crypto positions with -USD symbols")
  func positions() async throws {
    let store = FixtureStore()
    try store.register(
      key: FixtureKey(method: "GET", path: "/api/v3/brokerage/accounts"),
      fixtureNamed: "accounts",
      in: Bundle.module
    )
    let session = ReplayURLProtocol.makeSession(store: store)
    defer { ReplayURLProtocol.deregister(session: session) }

    let provider = try await Self.makeAuthenticatedProvider(session: session)
    let positions = try await provider.positions(for: AccountID(rawValue: "ignored"))

    // The LTC wallet has a zero balance and is dropped; BTC and ETH remain.
    #expect(positions.count == 2)
    #expect(positions.allSatisfy { $0.assetClass == .crypto })
    let btc = try #require(positions.first { $0.symbol == Symbol(rawValue: "BTC-USD") })
    #expect(btc.quantity == Decimal(string: "0.5"))
    #expect(positions.contains { $0.symbol == Symbol(rawValue: "ETH-USD") })
    #expect(!positions.contains { $0.symbol == Symbol(rawValue: "LTC-USD") })
  }

  @Test("balance sums available and hold into a Balance")
  func balance() async throws {
    let store = FixtureStore()
    try store.register(
      key: FixtureKey(method: "GET", path: "/api/v3/brokerage/accounts"),
      fixtureNamed: "accounts",
      in: Bundle.module
    )
    let session = ReplayURLProtocol.makeSession(store: store)
    defer { ReplayURLProtocol.deregister(session: session) }

    let provider = try await Self.makeAuthenticatedProvider(session: session)
    let balance = try await provider.balance(
      for: AccountID(rawValue: "00000000-0000-0000-0000-0000000000et")
    )

    #expect(balance.cash.amount == Decimal(string: "2.25"))
    #expect(balance.total.amount == Decimal(string: "2.35"))
    #expect(balance.total.currency == CurrencyCode(rawValue: "ETH"))
  }

  @Test("quote maps the ticker's latest trade to a Quote")
  func quote() async throws {
    let store = FixtureStore()
    try store.register(
      key: FixtureKey(method: "GET", path: "/api/v3/brokerage/products/BTC-USD/ticker"),
      fixtureNamed: "ticker",
      in: Bundle.module
    )
    let session = ReplayURLProtocol.makeSession(store: store)
    defer { ReplayURLProtocol.deregister(session: session) }

    let provider = try await Self.makeAuthenticatedProvider(session: session)
    let quote = try await provider.quote(for: Symbol(rawValue: "BTC-USD"))

    #expect(quote.symbol == Symbol(rawValue: "BTC-USD"))
    #expect(quote.last.amount == Decimal(string: "61234.56"))
  }

  @Test("priceHistory maps candles to a PerformanceSeries of Decimal closes")
  func priceHistory() async throws {
    let store = FixtureStore()
    try store.register(
      key: FixtureKey(method: "GET", path: "/api/v3/brokerage/products/BTC-USD/candles"),
      fixtureNamed: "candles",
      in: Bundle.module
    )
    let session = ReplayURLProtocol.makeSession(store: store)
    defer { ReplayURLProtocol.deregister(session: session) }

    let provider = try await Self.makeAuthenticatedProvider(session: session)
    let series = try await provider.priceHistory(
      symbol: Symbol(rawValue: "BTC-USD"),
      range: .threeMonths
    )

    // .threeMonths maps to a daily granularity (Coinbase ONE_DAY).
    #expect(series.granularity == .oneDay)
    #expect(series.points.count == 3)
    // Points are ordered oldest to newest and carry the candle close.
    #expect(series.points.first?.value.amount == Decimal(string: "43000"))
    #expect(series.points.last?.value.amount == Decimal(string: "44900"))
    #expect((series.points.first?.timestamp ?? .now) < (series.points.last?.timestamp ?? .distantPast))
  }

  // MARK: Granularity mapping

  @Test("TimeRange granularities map to Coinbase's candle enum")
  func granularityMapping() {
    #expect(CoinbaseProvider.coinbaseGranularity(for: .oneMinute) == "ONE_MINUTE")
    #expect(CoinbaseProvider.coinbaseGranularity(for: .fiveMinutes) == "FIVE_MINUTE")
    #expect(CoinbaseProvider.coinbaseGranularity(for: .fifteenMinutes) == "FIFTEEN_MINUTE")
    #expect(CoinbaseProvider.coinbaseGranularity(for: .oneHour) == "ONE_HOUR")
    #expect(CoinbaseProvider.coinbaseGranularity(for: .oneDay) == "ONE_DAY")
    // Coinbase has no weekly candle; long ranges fall back to daily.
    #expect(CoinbaseProvider.coinbaseGranularity(for: .oneWeek) == "ONE_DAY")
    // .oneDay range uses minute candles.
    #expect(CoinbaseProvider.coinbaseGranularity(for: TimeRange.oneDay.granularity) == "ONE_MINUTE")
  }

  // MARK: Authentication / PKCE (no network)

  @Test("authorization URL carries client_id, scopes, state and S256 PKCE challenge")
  func authorizationURL() async throws {
    let provider = try CoinbaseProvider(
      configuration: Self.configuration(),
      tokenStore: InMemoryTokenStore(),
      now: { Self.fixedNow },
      makeState: { "fixed-state-123" }
    )
    let session = try await provider.authenticate() as? CoinbaseAuthSession
    let auth = try #require(session)

    let url = await provider.authorizationURL(challenge: auth.pkce.challenge, state: auth.state)
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

    #expect(value("response_type") == "code")
    #expect(value("client_id") == "synthetic-client-id")
    #expect(value("redirect_uri") == "stockcharts://oauth/coinbase")
    #expect(value("scope") == "wallet:accounts:read wallet:transactions:read")
    #expect(value("state") == "fixed-state-123")
    #expect(value("code_challenge") == auth.pkce.challenge)
    #expect(value("code_challenge_method") == "S256")
  }

  @Test("PKCE challenge equals base64url(SHA256(verifier)) for a known verifier")
  func pkceChallengeMatches() {
    // A fixed verifier with an independently computed expected challenge.
    let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    let expected = Data(SHA256.hash(data: Data(verifier.utf8)))
      .base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    #expect(PKCE.challenge(forVerifier: verifier) == expected)

    // And a freshly generated pair is internally consistent.
    let pkce = PKCE()
    #expect(PKCE.challenge(forVerifier: pkce.verifier) == pkce.challenge)
    #expect(!pkce.challenge.contains("=") && !pkce.challenge.contains("+") && !pkce.challenge.contains("/"))
  }

  @Test("token exchange stores a token and flips authenticationStatus to .connected")
  func tokenExchangeConnects() async throws {
    let store = FixtureStore()
    try store.register(
      key: FixtureKey(method: "POST", path: "/oauth2/token"),
      fixtureNamed: "token",
      in: Bundle.module
    )
    let session = ReplayURLProtocol.makeSession(store: store)
    defer { ReplayURLProtocol.deregister(session: session) }

    let tokenStore = InMemoryTokenStore()
    let provider = try CoinbaseProvider(
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
    var callback = URLComponents(string: "stockcharts://oauth/coinbase")!
    callback.queryItems = [
      URLQueryItem(name: "code", value: "synthetic-auth-code"),
      URLQueryItem(name: "state", value: "fixed-state-123"),
    ]
    try await auth.complete(callbackURL: callback.url!)

    // A token was stored (the seeded synthetic value).
    let stored = try await tokenStore.secret("coinbase.coinbase")
    #expect(stored.contains("REDACTED-SYNTHETIC-ACCESS-TOKEN"))

    // After auth: connected.
    let after = await provider.authenticationStatus()
    guard case .connected(let connectionID) = after else {
      Issue.record("Expected connected after auth, got \(after)")
      return
    }
    #expect(connectionID == ConnectionID(rawValue: "coinbase"))
    #expect(store.hitCount(for: FixtureKey(method: "POST", path: "/oauth2/token")) == 1)
  }

  @Test("token exchange rejects a mismatched OAuth state")
  func stateMismatchRejected() async throws {
    let provider = try CoinbaseProvider(
      configuration: Self.configuration(),
      tokenStore: InMemoryTokenStore(),
      makeState: { "expected-state" }
    )
    let auth = try await provider.authenticate()
    var callback = URLComponents(string: "stockcharts://oauth/coinbase")!
    callback.queryItems = [
      URLQueryItem(name: "code", value: "synthetic-auth-code"),
      URLQueryItem(name: "state", value: "ATTACKER-STATE"),
    ]
    await #expect(throws: BrokerageError.self) {
      try await auth.complete(callbackURL: callback.url!)
    }
  }

  @Test("no client secret is required or stored (PKCE only)")
  func noClientSecretRequired() throws {
    // A configuration with only a client ID and redirect URI — no secret —
    // must construct successfully.
    let provider = try CoinbaseProvider(
      configuration: Self.configuration(),
      tokenStore: InMemoryTokenStore()
    )
    #expect(provider.capabilities.contains(.crypto))
    // The fixtures and configuration carry no "clientSecret" key.
    #expect(Self.configuration().secrets["clientSecret"] == nil)
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
