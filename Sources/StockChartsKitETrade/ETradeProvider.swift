import Foundation
import StockChartsKit
import os

/// The E*Trade API environment, selecting the base URL.
public enum ETradeEnvironment: Sendable {
  /// Production: `https://api.etrade.com`.
  case production
  /// Sandbox: `https://apisb.etrade.com`.
  case sandbox

  /// The API base URL for this environment.
  var baseURL: String {
    switch self {
    case .production: return "https://api.etrade.com"
    case .sandbox: return "https://apisb.etrade.com"
    }
  }
}

/// A read-only ``BrokerageProvider`` for E*Trade, backed by the official API
/// (`https://api.etrade.com`, or `https://apisb.etrade.com` in sandbox).
///
/// ## Authentication
/// E*Trade uses **OAuth 1.0a, three-legged** (PRD §9.3), signed with HMAC-SHA1
/// by ``OAuth1Signer``. ``authenticate()`` vends an ``AuthSession`` that drives
/// an ``AuthChallenge/pinCode(authorizationURL:)`` flow:
///
/// 1. The provider calls `GET /oauth/request_token` (signed with the consumer
///    secret, `oauth_callback=oob`) to obtain a request token/secret.
/// 2. It presents
///    `https://us.etrade.com/e/t/etws/authorize?key={consumerKey}&token={requestToken}`
///    as the challenge's authorization URL. The user logs in and copies the
///    verifier PIN.
/// 3. `complete(pinCode:)` calls `GET /oauth/access_token` with the
///    `oauth_verifier`, exchanging the request token + PIN for the access
///    token/secret, which is persisted via the injected ``TokenStore``.
///
/// Access tokens expire at **midnight US Eastern** and go inactive after two
/// hours of inactivity. They are renewed on demand via
/// `GET /oauth/renew_access_token` when a signed read fails with an
/// authorization error. Tokens are never logged.
///
/// ## Reads
/// Every read request is OAuth 1.0a-signed by an injected ``RequestSigner`` that
/// loads the stored access token/secret at send time and builds the
/// `Authorization: OAuth …` header, so the secret is never held as plaintext
/// state longer than a single request.
public actor ETradeProvider: BrokerageProvider {
  // MARK: nonisolated identity

  public nonisolated let id = ProviderID(rawValue: "etrade")
  public nonisolated let displayName = "E*Trade"
  public nonisolated let capabilities: Capabilities = [.positions, .balances, .quotes]
  public nonisolated let snapshotStore: (any SnapshotStore)?
  public nonisolated let marketData: (any MarketDataProvider)?

  // MARK: Endpoints

  /// The browser authorize endpoint (always production host, per E*Trade).
  static let authorizeEndpoint = "https://us.etrade.com/e/t/etws/authorize"

  // MARK: Configuration

  private let environment: ETradeEnvironment
  private let consumerKey: String
  private let consumerSecret: String
  private let connectionID: ConnectionID
  private let tokenStore: any TokenStore
  private let session: URLSession
  private let retryPolicy: RetryPolicy
  private let sleep: @Sendable (Duration) async throws -> Void
  private let now: @Sendable () -> Date
  private let signer: OAuth1Signer
  private let client: HTTPClient
  private let log = Logger(subsystem: "co.sstools.stockchartskit", category: "etrade")

  /// The base API URL for the configured environment.
  private var apiBase: String { environment.baseURL }

  /// The Keychain item key under which this connection's token pair is stored.
  private var tokenKey: String { "\(id.rawValue).\(connectionID.rawValue)" }

  // MARK: Auth state

  /// The in-flight session, retained so its request token/secret survive until
  /// the host supplies the verifier PIN.
  private var pendingSession: ETradeAuthSession?

  /// Creates an E*Trade provider.
  ///
  /// - Parameters:
  ///   - configuration: Developer-app credentials. Must carry the OAuth
  ///     consumer key under `"consumerKey"` and the consumer secret under
  ///     `"consumerSecret"`. Neither is logged.
  ///   - environment: Selects the production or sandbox base URL. Defaults to
  ///     `.production`.
  ///   - tokenStore: Where the per-user access token/secret is persisted. Pass
  ///     a ``KeychainStore`` in production; tests inject an in-memory store.
  ///   - connectionID: Groups this connection's stored tokens. Defaults to
  ///     `"etrade"`.
  ///   - session: The `URLSession` for all requests. Inject a replay-backed
  ///     session in tests; defaults to `.shared`.
  ///   - retryPolicy: HTTP retry policy. Defaults to ``RetryPolicy/default``.
  ///   - sleep: Wait primitive between retries. Defaults to `Task.sleep`.
  ///   - snapshotStore: Optional snapshot store backing `portfolioHistory`.
  ///   - marketData: Optional market-data source backing `portfolioHistory`.
  ///   - nonce: Supplies the OAuth nonce. Defaults to random; tests pin it.
  ///   - now: Supplies the current date for timestamps and `asOf` stamps.
  ///     Defaults to `Date.init`.
  /// - Throws: ``BrokerageError/authenticationFailed(reason:)`` if a required
  ///   configuration key is missing.
  public init(
    configuration: Configuration,
    environment: ETradeEnvironment = .production,
    tokenStore: any TokenStore,
    connectionID: ConnectionID = ConnectionID(rawValue: "etrade"),
    session: URLSession = .shared,
    retryPolicy: RetryPolicy = .default,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    snapshotStore: (any SnapshotStore)? = nil,
    marketData: (any MarketDataProvider)? = nil,
    nonce: @escaping @Sendable () -> String = { OAuth1Signer.randomNonce() },
    now: @escaping @Sendable () -> Date = Date.init
  ) throws {
    self.environment = environment
    self.consumerKey = try configuration.requiredSecret("consumerKey")
    self.consumerSecret = try configuration.requiredSecret("consumerSecret")
    self.connectionID = connectionID
    self.tokenStore = tokenStore
    self.session = session
    self.retryPolicy = retryPolicy
    self.sleep = sleep
    self.snapshotStore = snapshotStore
    self.marketData = marketData
    self.now = now

    let signer = OAuth1Signer(
      consumerKey: consumerKey,
      consumerSecret: consumerSecret,
      nonce: nonce,
      timestamp: now
    )
    self.signer = signer

    // The read signer loads the stored access token/secret per attempt and
    // signs the request's method + full URL, so the secret never lives as
    // long-lived state and timestamps/nonces are fresh on every retry.
    let key = "\(id.rawValue).\(connectionID.rawValue)"
    let store = tokenStore
    self.client = HTTPClient(
      providerID: id,
      session: session,
      signer: RequestSigner { request in
        let bundle = try await Self.loadBundle(from: store, key: key)
        guard let url = request.url else {
          throw BrokerageError.network(underlying: URLError(.badURL))
        }
        var signed = request
        let header = try signer.authorizationHeader(
          method: request.httpMethod ?? "GET",
          url: url,
          token: OAuth1Signer.Token(token: bundle.token, secret: bundle.secret)
        )
        signed.setValue(header, forHTTPHeaderField: "Authorization")
        return signed
      },
      retryPolicy: retryPolicy,
      sleep: sleep,
      now: now
    )
  }

  // MARK: Authentication

  public func authenticationStatus() async -> AuthenticationStatus {
    do {
      _ = try await Self.loadBundle(from: tokenStore, key: tokenKey)
      return .connected(connectionID: connectionID)
    } catch BrokerageError.notAuthenticated {
      return await requiresChallenge()
    } catch {
      return .error(Self.brokerageError(error))
    }
  }

  public func authenticate() async throws -> AuthSession {
    try await beginSession()
  }

  public func signOut() async throws {
    pendingSession = nil
    try await tokenStore.delete(tokenKey)
  }

  /// Clears the pending in-flight session. Called by the auth session on cancel.
  func clearPendingSession() {
    pendingSession = nil
  }

  /// Builds a `.requiresChallenge` status, starting the request-token leg.
  private func requiresChallenge() async -> AuthenticationStatus {
    do {
      let session = try await beginSession()
      let url = authorizeURL(requestToken: session.requestToken)
      return .requiresChallenge(.pinCode(authorizationURL: url))
    } catch {
      return .error(Self.brokerageError(error))
    }
  }

  /// Runs the request-token leg and retains a pending session.
  @discardableResult
  private func beginSession() async throws -> ETradeAuthSession {
    let (token, secret) = try await fetchRequestToken()
    let session = ETradeAuthSession(
      provider: self,
      requestToken: token,
      requestTokenSecret: secret
    )
    pendingSession = session
    return session
  }

  /// The browser authorize URL the host opens for the PIN flow.
  func authorizeURL(requestToken: String) -> URL {
    var components = URLComponents(string: Self.authorizeEndpoint)
    components?.queryItems = [
      URLQueryItem(name: "key", value: consumerKey),
      URLQueryItem(name: "token", value: requestToken),
    ]
    guard let url = components?.url else {
      preconditionFailure("Failed to build E*Trade authorize URL from a valid literal endpoint")
    }
    return url
  }

  // MARK: OAuth legs

  /// Leg 1: `GET /oauth/request_token` with `oauth_callback=oob`.
  private func fetchRequestToken() async throws -> (token: String, secret: String) {
    guard let url = URL(string: "\(apiBase)/oauth/request_token") else {
      throw BrokerageError.network(underlying: URLError(.badURL))
    }
    let header = try signer.authorizationHeader(
      method: "GET",
      url: url,
      token: .none,
      extraOAuthParameters: ["oauth_callback": "oob"]
    )
    let body = try await sendUnsignedExpectingForm(url: url, authorization: header)
    let fields = Self.parseFormEncoded(body)
    guard
      let token = fields["oauth_token"], !token.isEmpty,
      let secret = fields["oauth_token_secret"]
    else {
      throw BrokerageError.authenticationFailed(reason: "Malformed request_token response")
    }
    return (token, secret)
  }

  /// Leg 3: `GET /oauth/access_token` exchanging the request token + verifier.
  /// Called by the auth session on `complete(pinCode:)`.
  func exchangeAccessToken(
    requestToken: String,
    requestTokenSecret: String,
    verifier: String
  ) async throws {
    guard let url = URL(string: "\(apiBase)/oauth/access_token") else {
      throw BrokerageError.network(underlying: URLError(.badURL))
    }
    let header = try signer.authorizationHeader(
      method: "GET",
      url: url,
      token: OAuth1Signer.Token(token: requestToken, secret: requestTokenSecret),
      extraOAuthParameters: ["oauth_verifier": verifier]
    )
    let body = try await sendUnsignedExpectingForm(url: url, authorization: header)
    let fields = Self.parseFormEncoded(body)
    guard
      let token = fields["oauth_token"], !token.isEmpty,
      let secret = fields["oauth_token_secret"]
    else {
      throw BrokerageError.authenticationFailed(reason: "Malformed access_token response")
    }
    try await store(ETradeTokenBundle(token: token, secret: secret))
    pendingSession = nil
  }

  /// Renews the stored access token via `GET /oauth/renew_access_token`.
  ///
  /// E*Trade tokens expire at midnight US Eastern; this is invoked on demand to
  /// reactivate a token. The renewed token keeps the same value/secret, so the
  /// call simply confirms the token is active again.
  func renewAccessToken() async throws {
    let bundle = try await Self.loadBundle(from: tokenStore, key: tokenKey)
    guard let url = URL(string: "\(apiBase)/oauth/renew_access_token") else {
      throw BrokerageError.network(underlying: URLError(.badURL))
    }
    let header = try signer.authorizationHeader(
      method: "GET",
      url: url,
      token: OAuth1Signer.Token(token: bundle.token, secret: bundle.secret)
    )
    _ = try await sendUnsignedExpectingForm(url: url, authorization: header)
  }

  /// Sends a GET with a precomputed `Authorization` header (the OAuth legs sign
  /// themselves rather than going through the read signer) and returns the
  /// response body as text. Auth endpoints reply with form-encoded bodies.
  private func sendUnsignedExpectingForm(url: URL, authorization: String) async throws -> String {
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue(authorization, forHTTPHeaderField: "Authorization")
    let unsignedClient = HTTPClient(
      providerID: id,
      session: session,
      retryPolicy: retryPolicy,
      sleep: sleep,
      now: now
    )
    let data = try await unsignedClient.send(request)
    return String(data: data, encoding: .utf8) ?? ""
  }

  // MARK: Token persistence

  private func store(_ bundle: ETradeTokenBundle) async throws {
    let data = try JSONEncoder().encode(bundle)
    guard let json = String(data: data, encoding: .utf8) else {
      throw BrokerageError.authenticationFailed(reason: "Could not encode token bundle")
    }
    try await tokenStore.set(json, for: tokenKey)
  }

  /// Loads the persisted access-token pair. `Sendable` static so the read
  /// signer closure can call it without capturing the actor.
  private static func loadBundle(from store: any TokenStore, key: String) async throws
    -> ETradeTokenBundle
  {
    let json = try await store.secret(key)
    guard let data = json.data(using: .utf8) else {
      throw BrokerageError.notAuthenticated
    }
    return try JSONDecoder().decode(ETradeTokenBundle.self, from: data)
  }

  // MARK: Read

  public func listAccounts() async throws -> [Account] {
    let response = try await client.send(
      try makeGET(path: "/v1/accounts/list.json"),
      expecting: ETradeAccountListResponse.self
    )
    return response.accountListResponse.accounts.account.map { wire in
      Account(
        // The account is keyed on `accountIdKey` — the opaque key E*Trade uses
        // in portfolio/balance paths — not the human-facing `accountId`.
        id: AccountID(rawValue: wire.accountIdKey),
        providerID: id,
        displayName: wire.accountName?.isEmpty == false ? wire.accountName! : wire.accountId,
        kind: Self.accountKind(for: wire.accountType),
        baseCurrency: .usd,
        connectionID: connectionID
      )
    }
  }

  public func positions(for accountID: AccountID) async throws -> [Position] {
    let response = try await client.send(
      try makeGET(path: "/v1/accounts/\(accountID.rawValue)/portfolio.json"),
      expecting: ETradePortfolioResponse.self
    )
    let asOf = now()
    let positions = response.portfolioResponse.accountPortfolio
      .flatMap { $0.position ?? [] }
    return positions.map { wire in
      Position(
        accountID: accountID,
        symbol: Symbol(rawValue: wire.product.symbol),
        assetClass: Self.assetClass(for: wire.product.securityType),
        quantity: wire.quantity ?? 0,
        averageCost: wire.pricePaid.map { Money($0) },
        marketValue: Money(wire.marketValue ?? 0),
        unrealizedPL: wire.totalGain.map { Money($0) },
        asOf: asOf
      )
    }
  }

  public func balance(for accountID: AccountID) async throws -> Balance {
    var components = URLComponents(
      string: "\(apiBase)/v1/accounts/\(accountID.rawValue)/balance.json"
    )
    components?.queryItems = [
      URLQueryItem(name: "instType", value: "BROKERAGE"),
      URLQueryItem(name: "realTimeNAV", value: "true"),
    ]
    guard let url = components?.url else {
      throw BrokerageError.network(underlying: URLError(.badURL))
    }
    let response = try await client.send(
      URLRequest(url: url),
      expecting: ETradeBalanceResponse.self
    )
    let computed = response.balanceResponse.computed
    let total = computed?.realTimeValues?.totalAccountValue ?? computed?.cashBalance ?? 0
    let cash = computed?.cashAvailableForInvestment ?? computed?.cashBalance ?? 0
    let buyingPower = computed?.cashBuyingPower ?? computed?.marginBuyingPower
    return Balance(
      accountID: accountID,
      total: Money(total),
      cash: Money(cash),
      buyingPower: buyingPower.map { Money($0) },
      asOf: now()
    )
  }

  public func quote(for symbol: Symbol) async throws -> Quote {
    let response = try await client.send(
      try makeGET(path: "/v1/market/quote/\(symbol.rawValue).json"),
      expecting: ETradeQuoteResponse.self
    )
    guard let data = response.quoteResponse.quoteData.first else {
      throw BrokerageError.missingSymbol(symbol)
    }
    guard let last = data.all?.lastTrade else {
      throw BrokerageError.missingSymbol(symbol)
    }
    return Quote(
      symbol: symbol,
      last: Money(last),
      previousClose: data.all?.previousClose.map { Money($0) },
      asOf: now()
    )
  }

  public func priceHistory(
    symbol: Symbol,
    range: TimeRange
  ) async throws -> PerformanceSeries {
    // E*Trade exposes no per-symbol price history; the host falls back to a
    // MarketDataProvider.
    throw BrokerageError.unsupported(method: "priceHistory")
  }

  // MARK: Helpers

  private func makeGET(path: String) throws -> URLRequest {
    guard let url = URL(string: "\(apiBase)\(path)") else {
      throw BrokerageError.network(underlying: URLError(.badURL))
    }
    return URLRequest(url: url)
  }

  /// Parses an `application/x-www-form-urlencoded` body into key/value pairs.
  static func parseFormEncoded(_ body: String) -> [String: String] {
    var result: [String: String] = [:]
    for pair in body.split(separator: "&") {
      let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard let rawKey = parts.first else { continue }
      let key = String(rawKey).removingPercentEncoding ?? String(rawKey)
      let value = parts.count > 1 ? (String(parts[1]).removingPercentEncoding ?? String(parts[1])) : ""
      result[key] = value
    }
    return result
  }

  /// Maps an E*Trade `accountType` to an ``AccountKind``.
  static func accountKind(for accountType: String?) -> AccountKind {
    switch accountType?.uppercased() {
    case "MARGIN": return .margin
    case "CASH", "INDIVIDUAL", "BROKERAGE", "JOINT": return .brokerage
    case "IRA", "IRA_ROLLOVER", "SEP_IRA", "SIMPLE_IRA": return .ira
    case "ROTH_IRA": return .rothIRA
    default: return .brokerage
    }
  }

  /// Maps an E*Trade `securityType` to an ``AssetClass``.
  static func assetClass(for securityType: String?) -> AssetClass {
    switch securityType?.uppercased() {
    case "EQ", "EQUITY": return .equity
    case "ETF": return .etf
    case "MF", "MUTUAL_FUND": return .mutualFund
    case "OPTN", "OPTION": return .option
    case "BOND": return .bond
    default: return .equity
    }
  }

  /// Maps an arbitrary error to a ``BrokerageError`` without leaking detail.
  private static func brokerageError(_ error: Error) -> BrokerageError {
    if let brokerage = error as? BrokerageError { return brokerage }
    return BrokerageError.network(underlying: error)
  }
}
