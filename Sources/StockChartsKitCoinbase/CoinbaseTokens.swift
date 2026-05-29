import Foundation
import StockChartsKit

/// The persisted OAuth token bundle for a Coinbase connection.
///
/// Stored as a single JSON item in the ``TokenStore`` keyed by
/// `"coinbase.<connectionID>"`. Never logged.
struct TokenBundle: Codable, Sendable {
  /// The current bearer access token.
  var accessToken: String
  /// The refresh token, or empty if the issuer omitted one.
  var refreshToken: String
  /// When the access token expires, if known.
  var expiresAt: Date?

  /// Whether the access token is expired (with a small safety skew) as of `now`.
  func isExpired(now: Date) -> Bool {
    guard let expiresAt else { return false }
    // Refresh a minute early so a request never races the expiry boundary.
    return now.addingTimeInterval(60) >= expiresAt
  }
}

/// The token endpoint response shape (OAuth 2.0).
///
/// The shared `HTTPClient` decoder applies `.convertFromSnakeCase`, so the
/// wire's `access_token` / `refresh_token` / `expires_in` map to these
/// camelCase properties without explicit coding keys.
struct TokenResponse: Decodable, Sendable {
  let accessToken: String
  let refreshToken: String?
  let expiresIn: Int?
}

/// Vends a valid bearer access token to the request signer, refreshing it
/// through the OAuth token endpoint when expired.
///
/// This is a small `Sendable` collaborator (not the actor) so the signer closure
/// captures only what it needs. It is internally synchronized by an actor so
/// concurrent in-flight requests share one refresh rather than racing.
actor CoinbaseTokenProvider {
  private let tokenStore: any TokenStore
  private let tokenKey: String
  private let clientID: String
  private let tokenEndpoint: String
  private let session: URLSession
  private let now: @Sendable () -> Date

  init(
    tokenStore: any TokenStore,
    tokenKey: String,
    clientID: String,
    tokenEndpoint: String,
    session: URLSession,
    now: @escaping @Sendable () -> Date
  ) {
    self.tokenStore = tokenStore
    self.tokenKey = tokenKey
    self.clientID = clientID
    self.tokenEndpoint = tokenEndpoint
    self.session = session
    self.now = now
  }

  /// Returns a non-expired access token, refreshing if necessary.
  func validAccessToken() async throws -> String {
    let bundle = try await loadTokens()
    guard bundle.isExpired(now: now()) else {
      return bundle.accessToken
    }
    guard !bundle.refreshToken.isEmpty else {
      // Expired with no way to refresh: the caller must re-authenticate.
      throw BrokerageError.notAuthenticated
    }
    return try await refresh(using: bundle.refreshToken)
  }

  private func refresh(using refreshToken: String) async throws -> String {
    let response = try await postForm([
      "grant_type": "refresh_token",
      "refresh_token": refreshToken,
      "client_id": clientID,
    ])
    let expiresAt = response.expiresIn.map { now().addingTimeInterval(TimeInterval($0)) }
    let bundle = TokenBundle(
      accessToken: response.accessToken,
      // Coinbase may rotate the refresh token; keep the prior one if omitted.
      refreshToken: response.refreshToken ?? refreshToken,
      expiresAt: expiresAt
    )
    let data = try JSONEncoder().encode(bundle)
    if let json = String(data: data, encoding: .utf8) {
      try await tokenStore.set(json, for: tokenKey)
    }
    return response.accessToken
  }

  private func loadTokens() async throws -> TokenBundle {
    let json = try await tokenStore.secret(tokenKey)
    guard let data = json.data(using: .utf8) else {
      throw BrokerageError.notAuthenticated
    }
    return try JSONDecoder().decode(TokenBundle.self, from: data)
  }

  private func postForm(_ fields: [String: String]) async throws -> TokenResponse {
    guard let url = URL(string: tokenEndpoint) else {
      throw BrokerageError.network(underlying: URLError(.badURL))
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = Data(CoinbaseProvider.formEncode(fields).utf8)
    let client = HTTPClient(providerID: ProviderID(rawValue: "coinbase"), session: session, now: now)
    return try await client.send(request, expecting: TokenResponse.self)
  }
}
