import Foundation
import StockChartsKit

/// A read-only ``BrokerageProvider`` for Coinbase, backed by the Advanced Trade
/// API (`https://api.coinbase.com/api/v3/brokerage`).
///
/// ## Authentication
/// Coinbase uses **OAuth 2.0 with PKCE and no client secret** (PRD §5.1): only a
/// client ID is configured. ``authenticate()`` vends an ``AuthSession`` that
/// drives an ``AuthChallenge/oauthRedirect(authorizationURL:callbackScheme:)``
/// flow:
///
/// 1. The provider generates a PKCE verifier/challenge pair and builds an
///    authorization URL with `response_type=code`, the client ID, redirect URI,
///    the read scopes, an opaque `state`, and the S256 `code_challenge`.
/// 2. The host opens the URL, captures the redirect to its callback scheme, and
///    calls `complete(callbackURL:)`.
/// 3. The session validates `state`, exchanges the `code` (with the verifier)
///    for access/refresh tokens, and persists them via the injected
///    ``TokenStore``.
///
/// Access tokens are refreshed automatically when expired using the stored
/// refresh token. Tokens are never logged.
///
/// ## Reads
/// All read requests are signed with `Authorization: Bearer <access token>` by
/// an injected ``RequestSigner`` that fetches (and refreshes) the token from the
/// ``TokenStore`` at send time, so it is never held as plaintext state longer
/// than a single request.
public actor CoinbaseProvider: BrokerageProvider {
  // MARK: nonisolated identity

  public nonisolated let id = ProviderID(rawValue: "coinbase")
  public nonisolated let displayName = "Coinbase"
  public nonisolated let capabilities: Capabilities =
    [.positions, .balances, .quotes, .nativePriceHistory, .crypto]
  public nonisolated let snapshotStore: (any SnapshotStore)?
  public nonisolated let marketData: (any MarketDataProvider)?

  // MARK: Endpoints

  static let apiBase = "https://api.coinbase.com"
  static let authorizeEndpoint = "https://login.coinbase.com/oauth2/auth"
  static let tokenEndpoint = "https://login.coinbase.com/oauth2/token"
  static let scopes = ["wallet:accounts:read", "wallet:transactions:read"]

  // MARK: Configuration

  private let clientID: String
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

  /// The Keychain item key under which this connection's token bundle is stored.
  private var tokenKey: String { "\(id.rawValue).\(connectionID.rawValue)" }

  // MARK: Auth state

  /// The in-flight session, retained so its PKCE verifier survives until the
  /// host completes the redirect.
  private var pendingSession: CoinbaseAuthSession?

  /// Creates a Coinbase provider.
  ///
  /// - Parameters:
  ///   - configuration: Developer-app credentials. Must carry the OAuth client
  ///     ID under the key `"clientID"` and the redirect URI under `"redirectURI"`.
  ///     No client secret is read or required.
  ///   - tokenStore: Where per-user OAuth tokens are persisted. Pass a
  ///     ``KeychainStore`` in production; tests inject an in-memory store.
  ///   - connectionID: Groups this connection's stored tokens. Defaults to
  ///     `"coinbase"`.
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
    connectionID: ConnectionID = ConnectionID(rawValue: "coinbase"),
    session: URLSession = .shared,
    retryPolicy: RetryPolicy = .default,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    snapshotStore: (any SnapshotStore)? = nil,
    marketData: (any MarketDataProvider)? = nil,
    now: @escaping @Sendable () -> Date = Date.init,
    makeState: @escaping @Sendable () -> String = { UUID().uuidString }
  ) throws {
    self.clientID = try configuration.requiredSecret("clientID")
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
    // detached closure so it can capture only the small dependencies it needs
    // rather than the whole actor.
    let key = "\(id.rawValue).\(connectionID.rawValue)"
    let tokenProvider = CoinbaseTokenProvider(
      tokenStore: tokenStore,
      tokenKey: key,
      clientID: clientID,
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
    let session = CoinbaseAuthSession(
      provider: self,
      pkce: PKCE(),
      state: makeState()
    )
    pendingSession = session
    return session
  }

  public func signOut() async throws {
    pendingSession = nil
    try await tokenStore.delete(tokenKey)
  }

  /// Builds the OAuth authorization challenge using the pending session's PKCE
  /// pair, creating a session if one is not already in flight.
  private func makeChallenge() -> AuthChallenge {
    let session: CoinbaseAuthSession
    if let pending = pendingSession {
      session = pending
    } else {
      session = CoinbaseAuthSession(provider: self, pkce: PKCE(), state: makeState())
      pendingSession = session
    }
    return .oauthRedirect(
      authorizationURL: authorizationURL(challenge: session.pkce.challenge, state: session.state),
      callbackScheme: callbackScheme
    )
  }

  /// Builds the authorization URL for the OAuth redirect.
  func authorizationURL(challenge: String, state: String) -> URL {
    var components = URLComponents(string: Self.authorizeEndpoint)
    components?.queryItems = [
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "client_id", value: clientID),
      URLQueryItem(name: "redirect_uri", value: redirectURI),
      URLQueryItem(name: "scope", value: Self.scopes.joined(separator: " ")),
      URLQueryItem(name: "state", value: state),
      URLQueryItem(name: "code_challenge", value: challenge),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
    ]
    // Force-unwrap is provably safe: the endpoint is a valid literal and the
    // query items are well-formed.
    guard let url = components?.url else {
      preconditionFailure("Failed to build Coinbase authorization URL from a valid literal endpoint")
    }
    return url
  }

  // MARK: Token exchange (called by the auth session)

  /// Exchanges an authorization `code` for tokens and persists them.
  func exchangeCode(_ code: String, verifier: String) async throws {
    let body: [String: String] = [
      "grant_type": "authorization_code",
      "code": code,
      "client_id": clientID,
      "redirect_uri": redirectURI,
      "code_verifier": verifier,
    ]
    let response = try await postForm(body)
    try await store(response)
    pendingSession = nil
  }

  /// Posts a form-urlencoded body to the token endpoint and decodes the result.
  ///
  /// This bypasses the bearer signer (there is no token yet) by using the raw
  /// session-backed ``HTTPClient`` with an identity signer.
  private func postForm(_ fields: [String: String]) async throws -> TokenResponse {
    guard let url = URL(string: Self.tokenEndpoint) else {
      throw BrokerageError.network(underlying: URLError(.badURL))
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = Data(Self.formEncode(fields).utf8)

    let unsignedClient = HTTPClient(
      providerID: id,
      session: session,
      retryPolicy: retryPolicy,
      sleep: sleep,
      now: now
    )
    return try await unsignedClient.send(request, expecting: TokenResponse.self)
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
    let envelope = try await client.send(
      try makeGET(path: "/api/v3/brokerage/accounts"),
      expecting: AccountsEnvelope.self
    )
    return envelope.accounts.map { wire in
      Account(
        id: AccountID(rawValue: wire.uuid),
        providerID: id,
        displayName: wire.name ?? wire.currency,
        kind: .crypto,
        baseCurrency: CurrencyCode(rawValue: wire.currency),
        connectionID: connectionID
      )
    }
  }

  public func positions(for accountID: AccountID) async throws -> [Position] {
    let envelope = try await client.send(
      try makeGET(path: "/api/v3/brokerage/accounts"),
      expecting: AccountsEnvelope.self
    )
    let asOf = now()
    return envelope.accounts.compactMap { wire -> Position? in
      let quantity = wire.availableBalance?.value ?? 0
      guard quantity != 0 else { return nil }
      // Coinbase prices crypto positions in the wallet's own currency; the
      // package quotes against USD by convention, so the symbol is `<CCY>-USD`.
      let currency = wire.currency
      let symbol = Symbol(rawValue: "\(currency)-USD")
      return Position(
        accountID: AccountID(rawValue: wire.uuid),
        symbol: symbol,
        assetClass: .crypto,
        quantity: quantity,
        averageCost: nil,
        // Market value is the holding's own balance; the host can revalue in USD
        // via a quote/FX. The amount is expressed in the asset's currency.
        marketValue: Money(quantity, CurrencyCode(rawValue: currency)),
        unrealizedPL: nil,
        asOf: asOf
      )
    }
  }

  public func balance(for accountID: AccountID) async throws -> Balance {
    let envelope = try await client.send(
      try makeGET(path: "/api/v3/brokerage/accounts"),
      expecting: AccountsEnvelope.self
    )
    guard let wire = envelope.accounts.first(where: { $0.uuid == accountID.rawValue }) else {
      throw BrokerageError.providerError(
        providerID: id,
        statusCode: nil,
        message: "No account \(accountID.rawValue)"
      )
    }
    let currency = CurrencyCode(rawValue: wire.currency)
    let available = wire.availableBalance?.value ?? 0
    let hold = wire.hold?.value ?? 0
    return Balance(
      accountID: accountID,
      total: Money(available + hold, currency),
      cash: Money(available, currency),
      buyingPower: nil,
      asOf: now()
    )
  }

  public func quote(for symbol: Symbol) async throws -> Quote {
    let product = symbol.rawValue
    let ticker = try await client.send(
      try makeGET(path: "/api/v3/brokerage/products/\(product)/ticker"),
      expecting: TickerEnvelope.self
    )
    guard let trade = ticker.trades.first else {
      throw BrokerageError.missingSymbol(symbol)
    }
    return Quote(
      symbol: symbol,
      last: Money(trade.price),
      previousClose: nil,
      asOf: trade.time ?? now()
    )
  }

  public func priceHistory(
    symbol: Symbol,
    range: TimeRange
  ) async throws -> PerformanceSeries {
    let product = symbol.rawValue
    let interval = range.interval(now: now())
    let granularity = Self.coinbaseGranularity(for: range.granularity)
    var components = URLComponents(
      string: "\(Self.apiBase)/api/v3/brokerage/products/\(product)/candles"
    )
    components?.queryItems = [
      URLQueryItem(name: "start", value: String(Int(interval.start.timeIntervalSince1970))),
      URLQueryItem(name: "end", value: String(Int(interval.end.timeIntervalSince1970))),
      URLQueryItem(name: "granularity", value: granularity),
    ]
    guard let url = components?.url else {
      throw BrokerageError.missingSymbol(symbol)
    }
    let envelope = try await client.send(
      URLRequest(url: url),
      expecting: CandlesEnvelope.self
    )
    let points = envelope.candles
      .compactMap { candle -> PerformanceSeries.Point? in
        guard let start = candle.startDate else { return nil }
        return PerformanceSeries.Point(timestamp: start, value: Money(candle.close))
      }
      .sorted { $0.timestamp < $1.timestamp }
    return PerformanceSeries(
      subject: .symbol(symbol),
      range: range,
      points: points,
      granularity: range.granularity
    )
  }

  // MARK: Helpers

  private func makeGET(path: String) throws -> URLRequest {
    guard let url = URL(string: "\(Self.apiBase)\(path)") else {
      throw BrokerageError.network(underlying: URLError(.badURL))
    }
    return URLRequest(url: url)
  }

  /// Maps a package ``Granularity`` to Coinbase's candle granularity enum.
  static func coinbaseGranularity(for granularity: Granularity) -> String {
    switch granularity {
    case .oneMinute: return "ONE_MINUTE"
    case .fiveMinutes: return "FIVE_MINUTE"
    case .fifteenMinutes: return "FIFTEEN_MINUTE"
    case .oneHour: return "ONE_HOUR"
    case .oneDay: return "ONE_DAY"
    // Coinbase has no native weekly candle; daily is the coarsest supported, so
    // long ranges sample daily and the chart layer downsamples as needed.
    case .oneWeek: return "ONE_DAY"
    }
  }

  /// Maps an arbitrary error to a ``BrokerageError`` without leaking detail.
  private static func brokerageError(_ error: Error) -> BrokerageError {
    if let brokerage = error as? BrokerageError { return brokerage }
    return BrokerageError.network(underlying: error)
  }
}
