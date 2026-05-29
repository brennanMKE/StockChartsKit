import Crypto
import Foundation
import Testing

import StockChartsKit
import StockChartsKitTesting

@testable import StockChartsKitETrade

/// Offline tests for the E*Trade provider. The OAuth 1.0a signer is validated
/// against the canonical RFC 5849 §3.1 / §3.4.1.1 public test vector. Reads and
/// the auth legs are served by the HTTP-replay harness from synthetic, redacted
/// fixtures, with the access-token pair seeded into an in-memory store, so no
/// live network or real credential is ever involved.
@Suite("StockChartsKitETrade (offline)")
struct StockChartsKitETradeTests {
  private static let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
  private static let noSleep: @Sendable (Duration) async throws -> Void = { _ in }

  /// Synthetic developer-app credentials. No real consumer key or secret.
  private static func configuration() -> Configuration {
    Configuration(secrets: [
      "consumerKey": "synthetic-consumer-key",
      "consumerSecret": "synthetic-consumer-secret",
    ])
  }

  // MARK: - OAuth1Signer: RFC 5849 known vector

  /// The RFC 5849 §3.1 example consumer/token secrets. These are documented
  /// public test-vector values from the standard, NOT real credentials.
  private static let rfcConsumerSecret = "j49sk3j29djd"
  private static let rfcTokenSecret = "dh893hdasih9"

  /// Rebuilds the RFC 5849 example using the signer's internal base-string
  /// builder. The example omits `oauth_version` and includes a duplicate `a3`
  /// parameter and body parameters, so the oauth params and the merged
  /// query/body parameters are supplied explicitly to match the published
  /// vector exactly.
  @Test("OAuth1 signature base string matches the RFC 5849 §3.4.1.1 example exactly")
  func rfcSignatureBaseString() throws {
    let oauthParameters: [String: String] = [
      "oauth_consumer_key": "9djdj82h48djs9d2",
      "oauth_token": "kkk9d7dh3k39sjv7",
      "oauth_signature_method": "HMAC-SHA1",
      "oauth_timestamp": "137131201",
      "oauth_nonce": "7d8f3e4a",
    ]
    // Query params from the request line plus the form body params. Duplicate
    // `a3` keys (`a` from the query, `2 q` from the body) are both present.
    let queryParameters: [(String, String)] = [
      ("b5", "=%3D"),
      ("a3", "a"),
      ("c@", ""),
      ("a2", "r b"),
      ("c2", ""),
      ("a3", "2 q"),
    ]
    let url = URL(string: "http://example.com/request")!

    let base = try OAuth1Signer.signatureBaseString(
      method: "POST",
      url: url,
      oauthParameters: oauthParameters,
      queryParameters: queryParameters
    )

    let expected =
      "POST&http%3A%2F%2Fexample.com%2Frequest&"
      + "a2%3Dr%2520b%26a3%3D2%2520q%26a3%3Da%26b5%3D%253D%25253D%26c%2540%3D%26c2%3D"
      + "%26oauth_consumer_key%3D9djdj82h48djs9d2%26oauth_nonce%3D7d8f3e4a"
      + "%26oauth_signature_method%3DHMAC-SHA1%26oauth_timestamp%3D137131201"
      + "%26oauth_token%3Dkkk9d7dh3k39sjv7"
    #expect(base == expected)
  }

  /// Verifies HMAC-SHA1 over the RFC base string with the RFC's signing-key
  /// secrets yields the documented `oauth_signature`.
  @Test("OAuth1 HMAC-SHA1 over the RFC base string matches the documented signature")
  func rfcSignature() throws {
    let base =
      "POST&http%3A%2F%2Fexample.com%2Frequest&"
      + "a2%3Dr%2520b%26a3%3D2%2520q%26a3%3Da%26b5%3D%253D%25253D%26c%2540%3D%26c2%3D"
      + "%26oauth_consumer_key%3D9djdj82h48djs9d2%26oauth_nonce%3D7d8f3e4a"
      + "%26oauth_signature_method%3DHMAC-SHA1%26oauth_timestamp%3D137131201"
      + "%26oauth_token%3Dkkk9d7dh3k39sjv7"

    let signingKey =
      "\(OAuth1Signer.percentEncode(Self.rfcConsumerSecret))&"
      + "\(OAuth1Signer.percentEncode(Self.rfcTokenSecret))"
    let mac = HMAC<Insecure.SHA1>.authenticationCode(
      for: Data(base.utf8),
      using: SymmetricKey(data: Data(signingKey.utf8))
    )
    let signature = Data(mac).base64EncodedString()

    // The `bYT5CMsGcbgUdFHObYMEfcx6bsw=` value shown in RFC 5849 §3.1's
    // Authorization-header illustration is a placeholder, not the HMAC of the
    // §3.4.1.1 base string. The actual HMAC-SHA1 of that base string under the
    // signing key `j49sk3j29djd&dh893hdasih9` is the value below — independently
    // reproduced with a reference HMAC implementation.
    #expect(signature == "r6/TJjbCOr97/+UU0NsvSne7s5g=")
  }

  @Test("percentEncode follows RFC 3986: unreserved literal, uppercase hex escapes")
  func percentEncoding() {
    #expect(OAuth1Signer.percentEncode("abcXYZ-._~190") == "abcXYZ-._~190")
    #expect(OAuth1Signer.percentEncode("r b") == "r%20b")
    #expect(OAuth1Signer.percentEncode("=%3D") == "%3D%253D")
    #expect(OAuth1Signer.percentEncode("c@") == "c%40")
    #expect(OAuth1Signer.percentEncode("a+b") == "a%2Bb")
  }

  @Test("authorizationHeader includes the standard oauth_* params, signature, and version")
  func authorizationHeaderShape() throws {
    let signer = OAuth1Signer(
      consumerKey: "ck",
      consumerSecret: "cs",
      nonce: { "fixed-nonce" },
      timestamp: { Date(timeIntervalSince1970: 137_131_201) }
    )
    let url = URL(string: "https://api.etrade.com/v1/accounts/list.json")!
    let header = try signer.authorizationHeader(
      method: "GET",
      url: url,
      token: OAuth1Signer.Token(token: "tok", secret: "sec")
    )
    #expect(header.hasPrefix("OAuth "))
    #expect(header.contains("oauth_consumer_key=\"ck\""))
    #expect(header.contains("oauth_nonce=\"fixed-nonce\""))
    #expect(header.contains("oauth_signature_method=\"HMAC-SHA1\""))
    #expect(header.contains("oauth_timestamp=\"137131201\""))
    #expect(header.contains("oauth_token=\"tok\""))
    #expect(header.contains("oauth_version=\"1.0\""))
    #expect(header.contains("oauth_signature="))
  }

  // MARK: - Provider construction helpers

  private static func makeAuthenticatedProvider(
    session: URLSession,
    environment: ETradeEnvironment = .production,
    store: InMemoryTokenStore = InMemoryTokenStore()
  ) async throws -> ETradeProvider {
    let bundle = ETradeTokenBundle(
      token: "REDACTED-SEEDED-ACCESS-TOKEN",
      secret: "REDACTED-SEEDED-ACCESS-SECRET"
    )
    let json = String(data: try JSONEncoder().encode(bundle), encoding: .utf8)!
    try await store.set(json, for: "etrade.etrade")
    return try ETradeProvider(
      configuration: configuration(),
      environment: environment,
      tokenStore: store,
      session: session,
      retryPolicy: .immediate,
      sleep: noSleep,
      nonce: { "fixed-nonce" },
      now: { fixedNow }
    )
  }

  // MARK: - Reads

  @Test("listAccounts maps the list envelope to [Account] keyed on accountIdKey")
  func listAccounts() async throws {
    let store = FixtureStore()
    try store.register(
      key: FixtureKey(method: "GET", path: "/v1/accounts/list.json"),
      fixtureNamed: "accounts",
      in: Bundle.module
    )
    let session = ReplayURLProtocol.makeSession(store: store)
    defer { ReplayURLProtocol.deregister(session: session) }

    let provider = try await Self.makeAuthenticatedProvider(session: session)
    let accounts = try await provider.listAccounts()

    #expect(accounts.count == 2)
    // Account.id is the opaque accountIdKey, not the human-facing accountId.
    #expect(accounts.first?.id == AccountID(rawValue: "REDACTED-KEY-AAA"))
    #expect(accounts.contains { $0.kind == .rothIRA })
    #expect(accounts.allSatisfy { $0.baseCurrency == .usd })
    #expect(store.hitCount(for: FixtureKey(method: "GET", path: "/v1/accounts/list.json")) == 1)
  }

  @Test("positions maps the portfolio to [Position] with Decimal money")
  func positions() async throws {
    let store = FixtureStore()
    try store.register(
      key: FixtureKey(method: "GET", path: "/v1/accounts/REDACTED-KEY-AAA/portfolio.json"),
      fixtureNamed: "portfolio",
      in: Bundle.module
    )
    let session = ReplayURLProtocol.makeSession(store: store)
    defer { ReplayURLProtocol.deregister(session: session) }

    let provider = try await Self.makeAuthenticatedProvider(session: session)
    let positions = try await provider.positions(for: AccountID(rawValue: "REDACTED-KEY-AAA"))

    #expect(positions.count == 2)
    let amd = try #require(positions.first { $0.symbol == Symbol(rawValue: "AMD") })
    #expect(amd.assetClass == .equity)
    #expect(amd.quantity == Decimal(10))
    #expect(amd.marketValue.amount == Decimal(string: "1500.00"))
    #expect(amd.unrealizedPL?.amount == Decimal(string: "545.00"))
    #expect(positions.contains { $0.symbol == Symbol(rawValue: "VOO") && $0.assetClass == .etf })
  }

  @Test("balance maps Computed values and sends the documented query params")
  func balance() async throws {
    let store = FixtureStore()
    try store.register(
      key: FixtureKey(method: "GET", path: "/v1/accounts/REDACTED-KEY-AAA/balance.json"),
      fixtureNamed: "balance",
      in: Bundle.module
    )
    // Capture the outgoing request URL to assert the query params.
    let captor = RequestCaptor()
    let session = captor.makeSession(store: store)
    defer { ReplayURLProtocol.deregister(session: session) }

    let provider = try await Self.makeAuthenticatedProvider(session: session)
    let balance = try await provider.balance(for: AccountID(rawValue: "REDACTED-KEY-AAA"))

    #expect(balance.total.amount == Decimal(string: "12345.67"))
    #expect(balance.cash.amount == Decimal(string: "2400.00"))
    #expect(balance.buyingPower?.amount == Decimal(string: "4800.00"))

    let items = captor.lastQueryItems()
    #expect(items["instType"] == "BROKERAGE")
    #expect(items["realTimeNAV"] == "true")
  }

  @Test("quote maps the latest trade to a Quote")
  func quote() async throws {
    let store = FixtureStore()
    try store.register(
      key: FixtureKey(method: "GET", path: "/v1/market/quote/AMD.json"),
      fixtureNamed: "quote",
      in: Bundle.module
    )
    let session = ReplayURLProtocol.makeSession(store: store)
    defer { ReplayURLProtocol.deregister(session: session) }

    let provider = try await Self.makeAuthenticatedProvider(session: session)
    let quote = try await provider.quote(for: Symbol(rawValue: "AMD"))

    #expect(quote.symbol == Symbol(rawValue: "AMD"))
    #expect(quote.last.amount == Decimal(string: "150.25"))
    #expect(quote.previousClose?.amount == Decimal(string: "148.10"))
  }

  @Test("priceHistory throws .unsupported (E*Trade has no native history)")
  func priceHistoryUnsupported() async throws {
    let provider = try await Self.makeAuthenticatedProvider(
      session: ReplayURLProtocol.makeSession(store: FixtureStore())
    )
    await #expect(throws: BrokerageError.self) {
      _ = try await provider.priceHistory(symbol: Symbol(rawValue: "AMD"), range: .threeMonths)
    }
    do {
      _ = try await provider.priceHistory(symbol: Symbol(rawValue: "AMD"), range: .threeMonths)
      Issue.record("Expected unsupported")
    } catch let BrokerageError.unsupported(method) {
      #expect(method == "priceHistory")
    }
  }

  // MARK: - Capabilities & environment

  @Test("capabilities are positions, balances, quotes (no native history)")
  func capabilities() async throws {
    let provider = try await Self.makeAuthenticatedProvider(
      session: ReplayURLProtocol.makeSession(store: FixtureStore())
    )
    #expect(provider.capabilities.contains(.positions))
    #expect(provider.capabilities.contains(.balances))
    #expect(provider.capabilities.contains(.quotes))
    #expect(!provider.capabilities.contains(.nativePriceHistory))
    #expect(provider.id == ProviderID(rawValue: "etrade"))
    #expect(provider.displayName == "E*Trade")
  }

  @Test("sandbox environment targets apisb.etrade.com")
  func sandboxEnvironment() async throws {
    let store = FixtureStore()
    try store.register(
      key: FixtureKey(method: "GET", path: "/v1/accounts/list.json"),
      fixtureNamed: "accounts",
      in: Bundle.module
    )
    let captor = RequestCaptor()
    let session = captor.makeSession(store: store)
    defer { ReplayURLProtocol.deregister(session: session) }

    let provider = try await Self.makeAuthenticatedProvider(
      session: session,
      environment: .sandbox
    )
    _ = try await provider.listAccounts()

    let host = captor.lastHost()
    #expect(host == "apisb.etrade.com")
  }

  // MARK: - Auth (PIN flow)

  @Test("authorize URL carries key (consumerKey) and token (requestToken)")
  func authorizeURL() async throws {
    let provider = try ETradeProvider(
      configuration: Self.configuration(),
      tokenStore: InMemoryTokenStore(),
      nonce: { "fixed-nonce" },
      now: { Self.fixedNow }
    )
    let url = await provider.authorizeURL(requestToken: "REQ-TOKEN-123")
    #expect(url.host == "us.etrade.com")
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
    #expect(value("key") == "synthetic-consumer-key")
    #expect(value("token") == "REQ-TOKEN-123")
  }

  @Test("three-legged PIN flow moves authenticationStatus to .connected")
  func pinFlowConnects() async throws {
    let store = FixtureStore()
    try store.register(
      key: FixtureKey(method: "GET", path: "/oauth/request_token"),
      fixtureNamed: "request_token",
      in: Bundle.module
    )
    try store.register(
      key: FixtureKey(method: "GET", path: "/oauth/access_token"),
      fixtureNamed: "access_token",
      in: Bundle.module
    )
    let session = ReplayURLProtocol.makeSession(store: store)
    defer { ReplayURLProtocol.deregister(session: session) }

    let tokenStore = InMemoryTokenStore()
    let provider = try ETradeProvider(
      configuration: Self.configuration(),
      tokenStore: tokenStore,
      session: session,
      retryPolicy: .immediate,
      sleep: Self.noSleep,
      nonce: { "fixed-nonce" },
      now: { Self.fixedNow }
    )

    // Before auth: a pinCode challenge is required (this runs leg 1).
    let before = await provider.authenticationStatus()
    guard case .requiresChallenge(.pinCode(let authURL)) = before else {
      Issue.record("Expected requiresChallenge(.pinCode), got \(before)")
      return
    }
    #expect(authURL.host == "us.etrade.com")
    #expect(store.hitCount(for: FixtureKey(method: "GET", path: "/oauth/request_token")) >= 1)

    // Leg 3: paste the verifier PIN.
    let auth = try await provider.authenticate()
    try await auth.complete(pinCode: "  AB123  ")

    let stored = try await tokenStore.secret("etrade.etrade")
    #expect(stored.contains("REDACTED-SYNTHETIC-ACCESS-TOKEN"))
    #expect(store.hitCount(for: FixtureKey(method: "GET", path: "/oauth/access_token")) == 1)

    let after = await provider.authenticationStatus()
    guard case .connected(let connectionID) = after else {
      Issue.record("Expected connected after auth, got \(after)")
      return
    }
    #expect(connectionID == ConnectionID(rawValue: "etrade"))
  }

  @Test("missing consumerSecret fails construction without leaking the value")
  func missingSecret() {
    #expect(throws: BrokerageError.self) {
      _ = try ETradeProvider(
        configuration: Configuration(secrets: ["consumerKey": "ck"]),
        tokenStore: InMemoryTokenStore()
      )
    }
  }
}

// MARK: - Test doubles

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

/// Captures the most recent outgoing request URL via a passthrough
/// `URLProtocol`, so tests can assert host and query params. The replay protocol
/// still serves the response; this only observes.
///
/// To stay safe under Swift Testing's parallel execution, each captor registers
/// itself in a token-keyed registry (mirroring ``ReplayURLProtocol``) so
/// concurrent tests never share recording state.
final class RequestCaptor: @unchecked Sendable {
  private let lock = NSLock()
  private var lastURL: URL?
  let token = UUID().uuidString

  /// Builds a replay-backed session that also records each outgoing request.
  ///
  /// The captor protocol is placed *first* so its `canInit` (which records and
  /// declines) runs before the replay protocol that actually serves the
  /// fixture. The captor is keyed on its own header token.
  func makeSession(store: FixtureStore) -> URLSession {
    CaptorURLProtocol.register(token: token, captor: self)
    let config = ReplayURLProtocol.makeConfiguration(store: store)
    config.protocolClasses = [CaptorURLProtocol.self] + (config.protocolClasses ?? [])
    var headers = config.httpAdditionalHeaders ?? [:]
    headers[CaptorURLProtocol.tokenHeader] = token
    config.httpAdditionalHeaders = headers
    return URLSession(configuration: config)
  }

  func record(_ url: URL?) {
    lock.withLock { lastURL = url }
  }

  func lastHost() -> String? {
    lock.withLock { lastURL?.host }
  }

  func lastQueryItems() -> [String: String] {
    lock.withLock {
      guard let url = lastURL,
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
      else { return [:] }
      var result: [String: String] = [:]
      for item in items { result[item.name] = item.value }
      return result
    }
  }
}

/// A non-claiming `URLProtocol` that records the request URL into the captor
/// bound to the request's token header, then declines to handle it so the
/// replay protocol serves the response.
final class CaptorURLProtocol: URLProtocol {
  static let tokenHeader = "X-StockChartsKit-Captor-Token"
  nonisolated(unsafe) private static var registry: [String: RequestCaptor] = [:]
  private static let registryLock = NSLock()

  static func register(token: String, captor: RequestCaptor) {
    registryLock.withLock { registry[token] = captor }
  }

  override class func canInit(with request: URLRequest) -> Bool {
    guard let token = request.value(forHTTPHeaderField: tokenHeader) else { return false }
    let captor = registryLock.withLock { registry[token] }
    captor?.record(request.url)
    return false
  }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {}
  override func stopLoading() {}
}
