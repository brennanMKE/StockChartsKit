import Crypto
import Foundation
import Testing

import StockChartsKit
import StockChartsKitTesting

@testable import StockChartsKitSnapTrade

/// Offline tests for the SnapTrade integration. Reads, registration, and login
/// are served by the HTTP-replay harness from synthetic, redacted fixtures, so
/// no live network or real credential is ever involved. The HMAC signer is
/// validated for determinism and against an independently computed
/// HMAC-SHA256 over the exact signature-object bytes — there is no published
/// official SnapTrade HMAC vector, so the canonical server contract cannot be
/// vector-checked offline (see `Signing.swift`).
@Suite("StockChartsKitSnapTrade (offline)")
struct StockChartsKitSnapTradeTests {
  private static let fixedNow = Date(timeIntervalSince1970: 1_704_405_600)
  private static let fixedTimestamp: @Sendable () -> Int = { 1_704_405_600 }
  private static let noSleep: @Sendable (Duration) async throws -> Void = { _ in }

  /// Synthetic developer-app credentials — no real client id or consumer key.
  private static func configuration() -> Configuration {
    Configuration(secrets: [
      "clientId": "synthetic-client-id",
      "consumerKey": "synthetic-consumer-key",
    ])
  }

  /// An in-memory token store pre-seeded with synthetic user credentials.
  private static func seededStore() async throws -> InMemoryTokenStore {
    let store = InMemoryTokenStore()
    try await store.storeUserCredentials(
      SnapTradeUserCredentials(
        userId: "synthetic-user-id",
        userSecret: "REDACTED-SYNTHETIC-USER-SECRET"
      )
    )
    return store
  }

  // MARK: Signer

  @Test("signer is deterministic for identical inputs")
  func signerDeterminism() throws {
    let signer = SnapTradeSigner(consumerKey: "synthetic-consumer-key")
    let a = try signer.signature(path: "/api/v1/accounts", query: "clientId=abc&timestamp=123")
    let b = try signer.signature(path: "/api/v1/accounts", query: "clientId=abc&timestamp=123")
    #expect(a == b)
    // A different input yields a different signature.
    let c = try signer.signature(path: "/api/v1/accounts", query: "clientId=abc&timestamp=124")
    #expect(a != c)
  }

  @Test("signature equals an independently computed HMAC-SHA256 over the exact bytes")
  func signerMatchesIndependentHMAC() throws {
    let key = "synthetic-consumer-key"
    let signer = SnapTradeSigner(consumerKey: key)
    let path = "/api/v1/accounts"
    let query = "clientId=abc&timestamp=123&userId=u&userSecret=s"

    // The exact bytes the signer feeds to HMAC, for a bodiless (GET) request.
    let objectData = try signer.signatureObjectData(path: path, query: query, body: nil)
    // The canonical signature object must be sorted-key JSON with null content.
    let objectString = String(data: objectData, encoding: .utf8)
    #expect(objectString == #"{"content":null,"path":"/api/v1/accounts","query":"clientId=abc&timestamp=123&userId=u&userSecret=s"}"#)

    // Independently compute HMAC-SHA256 over those exact bytes.
    let mac = HMAC<SHA256>.authenticationCode(
      for: objectData,
      using: SymmetricKey(data: Data(key.utf8))
    )
    let expected = Data(mac).base64EncodedString()

    let actual = try signer.signature(path: path, query: query, body: nil)
    #expect(actual == expected)
  }

  @Test("signature object embeds parsed body content for POST requests")
  func signerBodyContent() throws {
    let signer = SnapTradeSigner(consumerKey: "k")
    let body = Data(#"{"userId":"u"}"#.utf8)
    let objectData = try signer.signatureObjectData(path: "/api/v1/snapTrade/login", query: "clientId=abc", body: body)
    let objectString = String(data: objectData, encoding: .utf8)
    #expect(objectString == #"{"content":{"userId":"u"},"path":"/api/v1/snapTrade/login","query":"clientId=abc"}"#)
  }

  @Test("canonical query sorts and percent-encodes parameters stably")
  func canonicalQueryStable() {
    let items = [
      URLQueryItem(name: "userSecret", value: "a b"),
      URLQueryItem(name: "clientId", value: "id"),
      URLQueryItem(name: "timestamp", value: "123"),
    ]
    let query = SnapTradeSigner.canonicalQuery(from: items)
    #expect(query == "clientId=id&timestamp=123&userSecret=a%20b")
  }

  // MARK: Namespaced id slugging

  @Test("brokerage names slugify into namespaced provider ids")
  func slugging() {
    #expect(ProviderID.snapTrade(brokerageName: "Robinhood") == ProviderID(rawValue: "snaptrade.robinhood"))
    #expect(ProviderID.snapTrade(brokerageName: "Fidelity") == ProviderID(rawValue: "snaptrade.fidelity"))
    #expect(ProviderID.snapTrade(brokerageName: "Fidelity NetBenefits") == ProviderID(rawValue: "snaptrade.fidelity-netbenefits"))
    #expect(ProviderID.snapTrade(brokerageName: "Wells Fargo") == ProviderID(rawValue: "snaptrade.wells-fargo"))
    #expect(ProviderID.snapTrade(brokerageName: "E*Trade") == ProviderID(rawValue: "snaptrade.e-trade"))
  }

  // MARK: discover()

  @Test("discover groups accounts into one provider per connection with namespaced ids")
  func discoverYieldsOnePerConnection() async throws {
    let store = FixtureStore()
    try store.register(
      key: FixtureKey(method: "GET", path: "/api/v1/accounts"),
      fixtureNamed: "accounts",
      in: Bundle.module
    )
    let session = ReplayURLProtocol.makeSession(store: store)
    defer { ReplayURLProtocol.deregister(session: session) }

    let tokenStore = try await Self.seededStore()
    let providers = try await SnapTradeProviders.discover(
      configuration: Self.configuration(),
      tokenStore: tokenStore,
      session: session,
      retryPolicy: .immediate,
      sleep: Self.noSleep,
      now: { Self.fixedNow },
      timestamp: Self.fixedTimestamp
    )

    // Two connections (Robinhood + Fidelity), even though Fidelity has 2 accounts.
    #expect(providers.count == 2)
    let ids = Set(providers.map { $0.id })
    #expect(ids.contains(ProviderID(rawValue: "snaptrade.robinhood")))
    #expect(ids.contains(ProviderID(rawValue: "snaptrade.fidelity")))
    let names = Set(providers.map { $0.displayName })
    #expect(names == ["Robinhood", "Fidelity"])
    #expect(store.hitCount(for: FixtureKey(method: "GET", path: "/api/v1/accounts")) == 1)
  }

  // MARK: Reads (scoped per connection)

  /// Builds the Fidelity connection provider directly for read tests.
  private static func fidelityProvider(session: URLSession, store: InMemoryTokenStore) -> SnapTradeConnectionProvider {
    SnapTradeConnectionProvider(
      brokerageName: "Fidelity",
      authorizationID: "auth-fidelity",
      clientID: "synthetic-client-id",
      consumerKey: "synthetic-consumer-key",
      tokenStore: store,
      session: session,
      retryPolicy: .immediate,
      sleep: noSleep,
      now: { fixedNow },
      timestamp: fixedTimestamp
    )
  }

  @Test("listAccounts is scoped to the provider's connection")
  func listAccountsScoped() async throws {
    let store = FixtureStore()
    try store.register(
      key: FixtureKey(method: "GET", path: "/api/v1/accounts"),
      fixtureNamed: "accounts",
      in: Bundle.module
    )
    let session = ReplayURLProtocol.makeSession(store: store)
    defer { ReplayURLProtocol.deregister(session: session) }

    let tokenStore = try await Self.seededStore()
    let fidelity = Self.fidelityProvider(session: session, store: tokenStore)
    let accounts = try await fidelity.listAccounts()

    // Only the two Fidelity accounts, not the Robinhood one.
    #expect(accounts.count == 2)
    #expect(accounts.allSatisfy { $0.providerID == ProviderID(rawValue: "snaptrade.fidelity") })
    #expect(accounts.allSatisfy { $0.connectionID == ConnectionID(rawValue: "auth-fidelity") })
    #expect(accounts.contains { $0.id == AccountID(rawValue: "acct-fid-0001") })
    #expect(accounts.contains { $0.id == AccountID(rawValue: "acct-fid-0002") })
    #expect(!accounts.contains { $0.id == AccountID(rawValue: "acct-rh-0001") })
  }

  @Test("positions maps holdings to [Position] with Decimal money")
  func positions() async throws {
    let store = FixtureStore()
    try store.register(
      key: FixtureKey(method: "GET", path: "/api/v1/accounts/acct-fid-0001/positions"),
      fixtureNamed: "positions",
      in: Bundle.module
    )
    let session = ReplayURLProtocol.makeSession(store: store)
    defer { ReplayURLProtocol.deregister(session: session) }

    let tokenStore = try await Self.seededStore()
    let fidelity = Self.fidelityProvider(session: session, store: tokenStore)
    let positions = try await fidelity.positions(for: AccountID(rawValue: "acct-fid-0001"))

    // The symbol-less entry is dropped; AMD + VTI remain.
    #expect(positions.count == 2)
    let amd = try #require(positions.first { $0.symbol == Symbol(rawValue: "AMD") })
    #expect(amd.assetClass == .equity)
    #expect(amd.quantity == Decimal(string: "10"))
    #expect(amd.marketValue.amount == Decimal(string: "1502.50"))
    #expect(amd.averageCost?.amount == Decimal(string: "120.00"))
    #expect(amd.unrealizedPL?.amount == Decimal(string: "302.50"))
    let vti = try #require(positions.first { $0.symbol == Symbol(rawValue: "VTI") })
    #expect(vti.assetClass == .etf)
    #expect(vti.quantity == Decimal(string: "5.5"))
  }

  @Test("balance maps the first balance entry to a Balance")
  func balance() async throws {
    let store = FixtureStore()
    try store.register(
      key: FixtureKey(method: "GET", path: "/api/v1/accounts/acct-fid-0001/balances"),
      fixtureNamed: "balances",
      in: Bundle.module
    )
    let session = ReplayURLProtocol.makeSession(store: store)
    defer { ReplayURLProtocol.deregister(session: session) }

    let tokenStore = try await Self.seededStore()
    let fidelity = Self.fidelityProvider(session: session, store: tokenStore)
    let balance = try await fidelity.balance(for: AccountID(rawValue: "acct-fid-0001"))

    #expect(balance.cash.amount == Decimal(string: "1234.56"))
    #expect(balance.cash.currency == CurrencyCode.usd)
    #expect(balance.buyingPower?.amount == Decimal(string: "2469.12"))
  }

  @Test("quote and priceHistory throw .unsupported")
  func unsupportedReads() async throws {
    let tokenStore = try await Self.seededStore()
    let session = ReplayURLProtocol.makeSession(store: FixtureStore())
    defer { ReplayURLProtocol.deregister(session: session) }
    let fidelity = Self.fidelityProvider(session: session, store: tokenStore)

    await #expect(throws: BrokerageError.self) {
      _ = try await fidelity.quote(for: Symbol(rawValue: "AMD"))
    }
    await #expect(throws: BrokerageError.self) {
      _ = try await fidelity.priceHistory(symbol: Symbol(rawValue: "AMD"), range: .threeMonths)
    }
  }

  @Test("capabilities are positions and balances only")
  func capabilities() async throws {
    let tokenStore = try await Self.seededStore()
    let session = ReplayURLProtocol.makeSession(store: FixtureStore())
    defer { ReplayURLProtocol.deregister(session: session) }
    let fidelity = Self.fidelityProvider(session: session, store: tokenStore)
    #expect(fidelity.capabilities == [.positions, .balances])
    #expect(!fidelity.capabilities.contains(.quotes))
    #expect(!fidelity.capabilities.contains(.nativePriceHistory))
  }

  // MARK: Registration / login

  @Test("registerUser stores the issued userId/userSecret")
  func registerUserStoresCredentials() async throws {
    let store = FixtureStore()
    try store.register(
      key: FixtureKey(method: "POST", path: "/api/v1/snapTrade/registerUser"),
      fixtureNamed: "register_user",
      in: Bundle.module
    )
    let session = ReplayURLProtocol.makeSession(store: store)
    defer { ReplayURLProtocol.deregister(session: session) }

    let tokenStore = InMemoryTokenStore()
    let credentials = try await SnapTradeProviders.registerUser(
      userId: "synthetic-user-id",
      configuration: Self.configuration(),
      tokenStore: tokenStore,
      session: session,
      retryPolicy: .immediate,
      sleep: Self.noSleep,
      timestamp: Self.fixedTimestamp
    )
    #expect(credentials.userId == "synthetic-user-id")
    #expect(credentials.userSecret == "REDACTED-SYNTHETIC-USER-SECRET")

    // Persisted and reloadable.
    let reloaded = try await tokenStore.loadUserCredentials()
    #expect(reloaded == credentials)
    #expect(store.hitCount(for: FixtureKey(method: "POST", path: "/api/v1/snapTrade/registerUser")) == 1)
  }

  @Test("login yields a hosted-portal AuthChallenge")
  func loginYieldsHostedPortal() async throws {
    let store = FixtureStore()
    try store.register(
      key: FixtureKey(method: "POST", path: "/api/v1/snapTrade/login"),
      fixtureNamed: "login",
      in: Bundle.module
    )
    let session = ReplayURLProtocol.makeSession(store: store)
    defer { ReplayURLProtocol.deregister(session: session) }

    let tokenStore = try await Self.seededStore()
    let challenge = try await SnapTradeProviders.loginChallenge(
      configuration: Self.configuration(),
      tokenStore: tokenStore,
      session: session,
      retryPolicy: .immediate,
      sleep: Self.noSleep,
      timestamp: Self.fixedTimestamp
    )
    guard case .hostedPortal(let url) = challenge else {
      Issue.record("Expected hostedPortal, got \(challenge)")
      return
    }
    #expect(url.absoluteString == "https://app.snaptrade.com/connect?token=SYNTHETIC-CONNECT-TOKEN")
    #expect(store.hitCount(for: FixtureKey(method: "POST", path: "/api/v1/snapTrade/login")) == 1)
  }

  @Test("authenticationStatus reports connected when credentials are present")
  func authStatusConnected() async throws {
    let tokenStore = try await Self.seededStore()
    let session = ReplayURLProtocol.makeSession(store: FixtureStore())
    defer { ReplayURLProtocol.deregister(session: session) }
    let fidelity = Self.fidelityProvider(session: session, store: tokenStore)

    let status = await fidelity.authenticationStatus()
    guard case .connected(let connectionID) = status else {
      Issue.record("Expected connected, got \(status)")
      return
    }
    #expect(connectionID == ConnectionID(rawValue: "auth-fidelity"))
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
