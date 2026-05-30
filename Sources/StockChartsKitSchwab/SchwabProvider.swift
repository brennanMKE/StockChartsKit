import Foundation
import StockChartsKit
import os

/// A read-only ``BrokerageProvider`` for Charles Schwab, backed by the official
/// developer API (`https://api.schwabapi.com`).
///
/// ## Authentication
/// Schwab uses **OAuth 2.0, authorization-code** (PRD §9.4). A developer app is
/// registered on the Schwab developer portal, yielding a client ID and client
/// secret; the package reads both (plus the redirect URI) from
/// ``Configuration``. ``authenticate()`` vends an ``AuthSession`` that drives an
/// ``AuthChallenge/oauthRedirect(authorizationURL:callbackScheme:)`` flow:
///
/// 1. The provider builds an authorization URL with `response_type=code`, the
///    client ID, redirect URI, the read scope, and an opaque `state`.
/// 2. The host opens the URL, captures the redirect to its callback scheme, and
///    calls `complete(callbackURL:)`.
/// 3. The session validates `state`, extracts the `code`, and exchanges it at
///    Schwab's token endpoint. Unlike Coinbase's PKCE flow, Schwab authenticates
///    the *client* with **HTTP Basic auth** — `Authorization: Basic
///    base64(client_id:client_secret)` — for both the code exchange and refresh.
///    The resulting access/refresh tokens are persisted via the injected
///    ``TokenStore``.
///
/// Access tokens are refreshed automatically when expired using the stored
/// refresh token (`grant_type=refresh_token`, also Basic-authed). Tokens are
/// never logged.
///
/// ## Account number vs. hash
/// Schwab identifies accounts two ways: a human-facing `accountNumber` and an
/// opaque `hashValue` used in per-account request paths. `GET
/// /trader/v1/accounts/accountNumbers` returns the mapping. ``listAccounts()``
/// surfaces the **hash** as the ``AccountID`` (so `positions`/`balance` paths
/// work directly), mirroring how the E*Trade provider uses `accountIdKey` rather
/// than the visible `accountId`.
///
/// ## Reads
/// Every read request is signed with `Authorization: Bearer <access token>` by
/// an injected ``RequestSigner`` that fetches (and refreshes) the token from the
/// ``TokenStore`` at send time, so it is never held as plaintext state longer
/// than a single request.
public actor SchwabProvider: BrokerageProvider {
  // MARK: nonisolated identity

  public nonisolated let id = ProviderID(rawValue: "schwab")
  public nonisolated let displayName = "Schwab"
  public nonisolated let capabilities: Capabilities =
    [.positions, .balances, .quotes, .nativePriceHistory]
  public nonisolated let snapshotStore: (any SnapshotStore)?
  public nonisolated let marketData: (any MarketDataProvider)?

  // MARK: Endpoints

  static let traderBase = "https://api.schwabapi.com/trader/v1"
  static let marketDataBase = "https://api.schwabapi.com/marketdata/v1"
  static let authorizeEndpoint = "https://api.schwabapi.com/v1/oauth/authorize"
  static let tokenEndpoint = "https://api.schwabapi.com/v1/oauth/token"
  static let scope = "readonly"

  // MARK: Configuration

  private let clientID: String
  private let clientSecret: String
  private let redirectURI: String
  private let callbackScheme: String
  private let connectionID: ConnectionID
  private let tokenStore: any TokenStore
  private let client: HTTPClient
  private let session: URLSession
  private let retryPolicy: RetryPolicy
  private let sleep: @Sendable (Duration) async throws -> Void
  private let now: @Sendable () -> Date
  private let makeState: @Sendable () -> String
  private let log = Logger(subsystem: "co.sstools.stockchartskit", category: "schwab")

  /// The Keychain item key under which this connection's token bundle is stored.
  private var tokenKey: String { "\(id.rawValue).\(connectionID.rawValue)" }

  // MARK: Auth state

  /// The in-flight session, retained so its `state` survives until the host
  /// completes the redirect.
  private var pendingSession: SchwabAuthSession?

  /// Creates a Schwab provider.
  ///
  /// - Parameters:
  ///   - configuration: Developer-app credentials. Must carry the OAuth client
  ///     ID under `"clientID"`, the client secret under `"clientSecret"`, and
  ///     the redirect URI under `"redirectURI"`. None is logged.
  ///   - tokenStore: Where per-user OAuth tokens are persisted. Pass a
  ///     ``KeychainStore`` in production; tests inject an in-memory store.
  ///   - connectionID: Groups this connection's stored tokens. Defaults to
  ///     `"schwab"`.
  ///   - session: The `URLSession` for all requests. Inject a replay-backed
  ///     session in tests; defaults to `.shared`.
  ///   - retryPolicy: HTTP retry policy. Defaults to ``RetryPolicy/default``.
  ///   - sleep: Wait primitive between retries. Defaults to `Task.sleep`.
  ///   - snapshotStore: Optional snapshot store backing `portfolioHistory`.
  ///   - marketData: Optional market-data source backing `portfolioHistory`.
  ///   - now: Supplies the current date for token-expiry math. Defaults to
  ///     `Date.init`.
  ///   - makeState: Generates the OAuth `state` value. Defaults to a random
  ///     UUID; tests inject a fixed value.
  /// - Throws: ``BrokerageError/authenticationFailed(reason:)`` if a required
  ///   configuration key is missing.
  public init(
    configuration: Configuration,
    tokenStore: any TokenStore,
    connectionID: ConnectionID = ConnectionID(rawValue: "schwab"),
    session: URLSession = .shared,
    retryPolicy: RetryPolicy = .default,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    snapshotStore: (any SnapshotStore)? = nil,
    marketData: (any MarketDataProvider)? = nil,
    now: @escaping @Sendable () -> Date = Date.init,
    makeState: @escaping @Sendable () -> String = { UUID().uuidString }
  ) throws {
    self.clientID = try configuration.requiredSecret("clientID")
    self.clientSecret = try configuration.requiredSecret("clientSecret")
    self.redirectURI = try configuration.requiredSecret("redirectURI")
    self.callbackScheme = Self.scheme(from: redirectURI)
    self.connectionID = connectionID
    self.tokenStore = tokenStore
    self.session = session
    self.retryPolicy = retryPolicy
    self.sleep = sleep
    self.snapshotStore = snapshotStore
    self.marketData = marketData
    self.now = now
    self.makeState = makeState

    // The signer fetches a fresh, valid bearer token for every attempt. It is a
    // detached collaborator so it captures only the small dependencies it needs
    // rather than the whole actor.
    let key = "\(id.rawValue).\(connectionID.rawValue)"
    let tokenProvider = SchwabTokenProvider(
      tokenStore: tokenStore,
      tokenKey: key,
      clientID: clientID,
      clientSecret: clientSecret,
      tokenEndpoint: Self.tokenEndpoint,
      session: session,
      now: now
    )
    self.client = HTTPClient(
      providerID: id,
      session: session,
      signer: RequestSigner { request in
        var signed = request
        let token = try await tokenProvider.validAccessToken()
        signed.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return signed
      },
      retryPolicy: retryPolicy,
      sleep: sleep,
      now: now
    )
  }

  /// Extracts the URL scheme (callback scheme) from a redirect URI.
  private static func scheme(from redirectURI: String) -> String {
    URLComponents(string: redirectURI)?.scheme ?? redirectURI
  }

  // MARK: Authentication

  public func authenticationStatus() async -> AuthenticationStatus {
    do {
      let bundle = try await loadTokens()
      // A stored refresh token means we can always mint a fresh access token,
      // so the connection is usable even if the access token has expired.
      if !bundle.refreshToken.isEmpty || !bundle.isExpired(now: now()) {
        return .connected(connectionID: connectionID)
      }
    } catch BrokerageError.notAuthenticated {
      // Fall through to a challenge.
    } catch {
      return .error(Self.brokerageError(error))
    }
    return .requiresChallenge(makeChallenge())
  }

  public func authenticate() async throws -> AuthSession {
    let session = SchwabAuthSession(provider: self, state: makeState())
    pendingSession = session
    return session
  }

  public func signOut() async throws {
    pendingSession = nil
    try await tokenStore.delete(tokenKey)
  }

  /// Clears the pending in-flight session. Called by the auth session on cancel.
  func clearPendingSession() {
    pendingSession = nil
  }

  /// Builds the OAuth authorization challenge, creating a session if one is not
  /// already in flight.
  private func makeChallenge() -> AuthChallenge {
    let session: SchwabAuthSession
    if let pending = pendingSession {
      session = pending
    } else {
      session = SchwabAuthSession(provider: self, state: makeState())
      pendingSession = session
    }
    return .oauthRedirect(
      authorizationURL: authorizationURL(state: session.state),
      callbackScheme: callbackScheme
    )
  }

  /// Builds the authorization URL for the OAuth redirect.
  func authorizationURL(state: String) -> URL {
    var components = URLComponents(string: Self.authorizeEndpoint)
    components?.queryItems = [
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "client_id", value: clientID),
      URLQueryItem(name: "redirect_uri", value: redirectURI),
      URLQueryItem(name: "scope", value: Self.scope),
      URLQueryItem(name: "state", value: state),
    ]
    // Force-unwrap is provably safe: the endpoint is a valid literal and the
    // query items are well-formed.
    guard let url = components?.url else {
      preconditionFailure("Failed to build Schwab authorization URL from a valid literal endpoint")
    }
    return url
  }

  // MARK: Token exchange (called by the auth session)

  /// Exchanges an authorization `code` for tokens and persists them.
  ///
  /// The exchange authenticates the client with HTTP Basic auth, not a body
  /// `client_id`/`client_secret` pair.
  func exchangeCode(_ code: String) async throws {
    let response = try await postToken([
      "grant_type": "authorization_code",
      "code": code,
      "redirect_uri": redirectURI,
    ])
    try await store(response)
    pendingSession = nil
  }

  /// Posts a form-urlencoded body to the token endpoint (Basic-authed) and
  /// decodes the result. Bypasses the bearer signer (there is no token yet).
  private func postToken(_ fields: [String: String]) async throws -> TokenResponse {
    guard
      let request = Self.tokenRequest(
        endpoint: Self.tokenEndpoint,
        fields: fields,
        clientID: clientID,
        clientSecret: clientSecret
      )
    else {
      throw BrokerageError.network(underlying: URLError(.badURL))
    }
    let unsignedClient = HTTPClient(
      providerID: id,
      session: session,
      retryPolicy: retryPolicy,
      sleep: sleep,
      now: now
    )
    return try await unsignedClient.send(request, expecting: TokenResponse.self)
  }

  /// Builds a Basic-authed, form-encoded POST to Schwab's token endpoint.
  ///
  /// Shared by the code-exchange (``SchwabProvider``) and the refresh
  /// (``SchwabTokenProvider``) paths. Exposed `internal`/`static` so tests can
  /// assert the `Authorization: Basic …` header for known credentials.
  static func tokenRequest(
    endpoint: String,
    fields: [String: String],
    clientID: String,
    clientSecret: String
  ) -> URLRequest? {
    guard let url = URL(string: endpoint) else { return nil }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue(basicAuthHeader(clientID: clientID, clientSecret: clientSecret),
      forHTTPHeaderField: "Authorization")
    request.httpBody = Data(formEncode(fields).utf8)
    return request
  }

  /// Computes the `Authorization: Basic …` header value for the given client
  /// credentials: `"Basic " + base64(clientID + ":" + clientSecret)`.
  static func basicAuthHeader(clientID: String, clientSecret: String) -> String {
    let credentials = "\(clientID):\(clientSecret)"
    let encoded = Data(credentials.utf8).base64EncodedString()
    return "Basic \(encoded)"
  }

  /// Persists a freshly issued token response as a `TokenBundle`.
  private func store(_ response: TokenResponse) async throws {
    let expiresAt = response.expiresIn.map { now().addingTimeInterval(TimeInterval($0)) }
    let bundle = TokenBundle(
      accessToken: response.accessToken,
      refreshToken: response.refreshToken ?? "",
      expiresAt: expiresAt
    )
    let data = try JSONEncoder().encode(bundle)
    guard let json = String(data: data, encoding: .utf8) else {
      throw BrokerageError.authenticationFailed(reason: "Could not encode token bundle")
    }
    try await tokenStore.set(json, for: tokenKey)
  }

  /// Reads the persisted token bundle.
  private func loadTokens() async throws -> TokenBundle {
    let json = try await tokenStore.secret(tokenKey)
    guard let data = json.data(using: .utf8) else {
      throw BrokerageError.notAuthenticated
    }
    return try JSONDecoder().decode(TokenBundle.self, from: data)
  }

  static func formEncode(_ fields: [String: String]) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return fields
      .sorted { $0.key < $1.key }
      .map { key, value in
        let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
        let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        return "\(k)=\(v)"
      }
      .joined(separator: "&")
  }

  // MARK: Read

  public func listAccounts() async throws -> [Account] {
    // The numbers endpoint maps each visible account number to the hashed key
    // used in per-account paths.
    let mappings = try await client.send(
      try makeGET(base: Self.traderBase, path: "/accounts/accountNumbers"),
      expecting: [SchwabAccountNumberMapping].self
    )
    let accounts = try await client.send(
      try makeGET(base: Self.traderBase, path: "/accounts"),
      expecting: [SchwabAccountEnvelope].self
    )
    let hashByNumber = Dictionary(
      mappings.map { ($0.accountNumber, $0.hashValue) },
      uniquingKeysWith: { first, _ in first }
    )
    return accounts.map { envelope in
      let securities = envelope.securitiesAccount
      // Prefer the hashed key (used in per-account request paths); fall back to
      // the visible number if the mapping is unavailable.
      let hash = hashByNumber[securities.accountNumber] ?? securities.accountNumber
      return Account(
        id: AccountID(rawValue: hash),
        providerID: id,
        displayName: "\(displayName) \(securities.accountNumber)",
        kind: Self.accountKind(for: securities.type),
        baseCurrency: .usd,
        connectionID: connectionID
      )
    }
  }

  public func positions(for accountID: AccountID) async throws -> [Position] {
    var components = URLComponents(
      string: "\(Self.traderBase)/accounts/\(accountID.rawValue)"
    )
    components?.queryItems = [URLQueryItem(name: "fields", value: "positions")]
    guard let url = components?.url else {
      throw BrokerageError.network(underlying: URLError(.badURL))
    }
    let envelope = try await client.send(
      URLRequest(url: url),
      expecting: SchwabAccountEnvelope.self
    )
    let asOf = now()
    let positions = envelope.securitiesAccount.positions ?? []
    return positions.map { wire in
      // Schwab reports long and short legs separately; net them for the package's
      // single signed quantity.
      let quantity = (wire.longQuantity ?? 0) - (wire.shortQuantity ?? 0)
      return Position(
        accountID: accountID,
        symbol: Symbol(rawValue: wire.instrument.symbol),
        assetClass: Self.assetClass(for: wire.instrument.assetType),
        quantity: quantity,
        averageCost: wire.averagePrice.map { Money($0) },
        marketValue: Money(wire.marketValue ?? 0),
        unrealizedPL: wire.longOpenProfitLoss.map { Money($0) },
        asOf: asOf
      )
    }
  }

  public func balance(for accountID: AccountID) async throws -> Balance {
    let envelope = try await client.send(
      try makeGET(base: Self.traderBase, path: "/accounts/\(accountID.rawValue)"),
      expecting: SchwabAccountEnvelope.self
    )
    let balances = envelope.securitiesAccount.currentBalances
    let total = balances?.liquidationValue ?? balances?.cashBalance ?? 0
    let cash = balances?.totalCash ?? balances?.cashBalance ?? 0
    return Balance(
      accountID: accountID,
      total: Money(total),
      cash: Money(cash),
      buyingPower: balances?.buyingPower.map { Money($0) },
      asOf: now()
    )
  }

  public func quote(for symbol: Symbol) async throws -> Quote {
    var components = URLComponents(string: "\(Self.marketDataBase)/quotes")
    components?.queryItems = [URLQueryItem(name: "symbols", value: symbol.rawValue)]
    guard let url = components?.url else {
      throw BrokerageError.missingSymbol(symbol)
    }
    // Schwab keys the response object by symbol.
    let entries = try await client.send(
      URLRequest(url: url),
      expecting: [String: SchwabQuoteEntry].self
    )
    guard let entry = entries[symbol.rawValue] ?? entries.values.first,
      let fields = entry.quote
    else {
      throw BrokerageError.missingSymbol(symbol)
    }
    guard let last = fields.lastPrice ?? fields.closePrice else {
      throw BrokerageError.missingSymbol(symbol)
    }
    let asOf = fields.quoteTime.map { Date(timeIntervalSince1970: $0 / 1000) } ?? now()
    return Quote(
      symbol: symbol,
      last: Money(last),
      previousClose: fields.closePrice.map { Money($0) },
      asOf: asOf
    )
  }

  public func priceHistory(
    symbol: Symbol,
    range: TimeRange
  ) async throws -> PerformanceSeries {
    let params = Self.priceHistoryParameters(for: range)
    var components = URLComponents(string: "\(Self.marketDataBase)/pricehistory")
    components?.queryItems = [
      URLQueryItem(name: "symbol", value: symbol.rawValue),
      URLQueryItem(name: "periodType", value: params.periodType),
      URLQueryItem(name: "period", value: String(params.period)),
      URLQueryItem(name: "frequencyType", value: params.frequencyType),
      URLQueryItem(name: "frequency", value: String(params.frequency)),
    ]
    guard let url = components?.url else {
      throw BrokerageError.missingSymbol(symbol)
    }
    let history = try await client.send(
      URLRequest(url: url),
      expecting: SchwabPriceHistory.self
    )
    let points = history.candles
      .compactMap { candle -> PerformanceSeries.Point? in
        guard let datetime = candle.datetime, let close = candle.close else { return nil }
        let timestamp = Date(timeIntervalSince1970: datetime / 1000)
        return PerformanceSeries.Point(timestamp: timestamp, value: Money(close))
      }
      .sorted { $0.timestamp < $1.timestamp }
    return PerformanceSeries(
      subject: .symbol(symbol),
      range: range,
      points: points,
      granularity: range.granularity
    )
  }

  // MARK: Price-history parameter mapping

  /// The Schwab `pricehistory` parameter bundle for a request.
  struct PriceHistoryParameters: Equatable, Sendable {
    let periodType: String
    let period: Int
    let frequencyType: String
    let frequency: Int
  }

  /// Maps a package ``TimeRange`` to Schwab `pricehistory` query parameters.
  ///
  /// Schwab's API takes a `periodType` (day/month/year/ytd), a `period` count,
  /// a `frequencyType` (minute/daily/weekly/monthly) and a `frequency` count.
  /// Intraday data is only available with `periodType=day`, so short ranges use
  /// minute candles; everything a month or longer uses daily candles, which the
  /// chart layer downsamples as needed:
  ///
  /// | TimeRange | periodType | period | frequencyType | frequency |
  /// |-----------|-----------|--------|---------------|-----------|
  /// | 1D        | day       | 1      | minute        | 1         |
  /// | 1W        | day       | 5      | minute        | 30        |
  /// | 1M        | month     | 1      | daily         | 1         |
  /// | 3M        | month     | 3      | daily         | 1         |
  /// | YTD       | ytd       | 1      | daily         | 1         |
  /// | 1Y        | year      | 1      | daily         | 1         |
  /// | 5Y        | year      | 5      | weekly        | 1         |
  /// | MAX       | year      | 20     | monthly       | 1         |
  static func priceHistoryParameters(for range: TimeRange) -> PriceHistoryParameters {
    switch range {
    case .oneDay:
      return .init(periodType: "day", period: 1, frequencyType: "minute", frequency: 1)
    case .oneWeek:
      return .init(periodType: "day", period: 5, frequencyType: "minute", frequency: 30)
    case .oneMonth:
      return .init(periodType: "month", period: 1, frequencyType: "daily", frequency: 1)
    case .threeMonths:
      return .init(periodType: "month", period: 3, frequencyType: "daily", frequency: 1)
    case .yearToDate:
      return .init(periodType: "ytd", period: 1, frequencyType: "daily", frequency: 1)
    case .oneYear:
      return .init(periodType: "year", period: 1, frequencyType: "daily", frequency: 1)
    case .fiveYears:
      return .init(periodType: "year", period: 5, frequencyType: "weekly", frequency: 1)
    case .max:
      return .init(periodType: "year", period: 20, frequencyType: "monthly", frequency: 1)
    }
  }

  // MARK: Helpers

  private func makeGET(base: String, path: String) throws -> URLRequest {
    guard let url = URL(string: "\(base)\(path)") else {
      throw BrokerageError.network(underlying: URLError(.badURL))
    }
    return URLRequest(url: url)
  }

  /// Maps a Schwab account `type` to an ``AccountKind``.
  static func accountKind(for type: String?) -> AccountKind {
    switch type?.uppercased() {
    case "MARGIN": return .margin
    case "CASH", "BROKERAGE": return .brokerage
    case "IRA": return .ira
    case "ROTH", "ROTH_IRA": return .rothIRA
    default: return .brokerage
    }
  }

  /// Maps a Schwab instrument `assetType` to an ``AssetClass``.
  static func assetClass(for assetType: String?) -> AssetClass {
    switch assetType?.uppercased() {
    case "EQUITY": return .equity
    case "ETF", "COLLECTIVE_INVESTMENT": return .etf
    case "MUTUAL_FUND": return .mutualFund
    case "OPTION": return .option
    case "FIXED_INCOME", "BOND": return .bond
    case "CURRENCY", "CASH_EQUIVALENT": return .cash
    default: return .equity
    }
  }

  /// Maps an arbitrary error to a ``BrokerageError`` without leaking detail.
  private static func brokerageError(_ error: Error) -> BrokerageError {
    if let brokerage = error as? BrokerageError { return brokerage }
    return BrokerageError.network(underlying: error)
  }
}
