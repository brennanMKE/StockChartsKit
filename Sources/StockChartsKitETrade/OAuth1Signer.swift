import Crypto
import Foundation

/// An error raised while building an OAuth 1.0a signature.
///
/// The error space is closed (PRD §14), so the signer is declared with typed
/// `throws(OAuth1Error)`. No case ever carries a secret value.
public enum OAuth1Error: Error, Sendable, Equatable {
  /// The request URL could not be parsed into scheme/host/path components.
  case invalidURL
}

/// OAuth 1.0a request signing with HMAC-SHA1 (RFC 5849), implemented with
/// `swift-crypto` — no third-party OAuth library (PRD §13).
///
/// The signer builds the signature base string
/// `METHOD&percentEncode(baseURL)&percentEncode(sortedEncodedParams)`, computes
/// `HMAC-SHA1(baseString, signingKey)` where the signing key is
/// `percentEncode(consumerSecret)&percentEncode(tokenSecret)`, base64-encodes
/// the digest as `oauth_signature`, and emits an `Authorization: OAuth …`
/// header.
///
/// Percent-encoding follows RFC 3986 §2.3: only the unreserved set
/// `ALPHA / DIGIT / "-" / "." / "_" / "~"` is left literal; everything else is
/// `%`-escaped with uppercase hex. This applies to the base-URL, every
/// parameter key/value in the base string, and the signing-key components.
///
/// The nonce and timestamp are injectable so tests can pin them to a known
/// vector and assert an exact signature.
public struct OAuth1Signer: Sendable {
  /// The developer-app consumer key (`oauth_consumer_key`).
  private let consumerKey: String
  /// The developer-app consumer secret, used to build the signing key. Never
  /// logged.
  private let consumerSecret: String
  /// Supplies a fresh nonce per signature. Defaults to a random hex string.
  private let nonce: @Sendable () -> String
  /// Supplies the request timestamp. Defaults to the current time.
  private let timestamp: @Sendable () -> Date

  /// Creates a signer.
  ///
  /// - Parameters:
  ///   - consumerKey: The `oauth_consumer_key`.
  ///   - consumerSecret: The consumer secret used in the signing key. Never
  ///     logged.
  ///   - nonce: Supplies the `oauth_nonce`. Defaults to 16 random bytes as hex;
  ///     tests inject a fixed value.
  ///   - timestamp: Supplies the time for `oauth_timestamp`. Defaults to
  ///     `Date.init`; tests inject a fixed value.
  public init(
    consumerKey: String,
    consumerSecret: String,
    nonce: @escaping @Sendable () -> String = { Self.randomNonce() },
    timestamp: @escaping @Sendable () -> Date = Date.init
  ) {
    self.consumerKey = consumerKey
    self.consumerSecret = consumerSecret
    self.nonce = nonce
    self.timestamp = timestamp
  }

  /// The token credentials applied to a signature, if any.
  ///
  /// Request-token requests carry no token; the access-token exchange carries
  /// the request token plus a verifier; ordinary reads carry the access token
  /// and its secret.
  public struct Token: Sendable {
    /// The `oauth_token` value, or `nil` for an unauthenticated request.
    public var token: String?
    /// The token secret used in the signing key, or `nil`/empty when none.
    public var secret: String?

    /// Creates a token pair.
    public init(token: String? = nil, secret: String? = nil) {
      self.token = token
      self.secret = secret
    }

    /// A token pair with neither token nor secret (request-token leg).
    public static let none = Token()
  }

  // MARK: Signing

  /// Builds the `Authorization: OAuth …` header value for a request.
  ///
  /// - Parameters:
  ///   - method: The HTTP method (e.g. `"GET"`).
  ///   - url: The full request URL, including any query items.
  ///   - token: Token credentials to include, if any.
  ///   - extraOAuthParameters: Additional `oauth_*` parameters such as
  ///     `oauth_callback` (request-token leg) or `oauth_verifier` (access-token
  ///     leg).
  /// - Returns: The complete header value, e.g. `OAuth oauth_consumer_key="…", …`.
  /// - Throws: ``OAuth1Error/invalidURL`` if `url` lacks a scheme or host.
  public func authorizationHeader(
    method: String,
    url: URL,
    token: Token = .none,
    extraOAuthParameters: [String: String] = [:]
  ) throws(OAuth1Error) -> String {
    let oauthParameters = try signedOAuthParameters(
      method: method,
      url: url,
      token: token,
      extraOAuthParameters: extraOAuthParameters
    )
    // The header lists only oauth_* parameters (not the query parameters that
    // were folded into the signature), each value percent-encoded and quoted,
    // sorted for stable output.
    let pairs = oauthParameters
      .sorted { $0.key < $1.key }
      .map { key, value in
        "\(Self.percentEncode(key))=\"\(Self.percentEncode(value))\""
      }
    return "OAuth " + pairs.joined(separator: ", ")
  }

  /// Computes the signature base string for a request.
  ///
  /// Exposed so tests can assert the base string matches a known vector exactly
  /// before checking the resulting signature.
  public func signatureBaseString(
    method: String,
    url: URL,
    token: Token = .none,
    extraOAuthParameters: [String: String] = [:],
    oauthNonce: String,
    oauthTimestamp: String
  ) throws(OAuth1Error) -> String {
    let oauthParameters = baseOAuthParameters(
      token: token,
      extraOAuthParameters: extraOAuthParameters,
      nonce: oauthNonce,
      timestamp: oauthTimestamp
    )
    return try Self.signatureBaseString(
      method: method,
      url: url,
      oauthParameters: oauthParameters,
      queryParameters: Self.queryParameters(from: url)
    )
  }

  /// Computes the base64 `oauth_signature` for a request, given fixed
  /// nonce/timestamp. Exposed for test-vector verification.
  public func signature(
    method: String,
    url: URL,
    token: Token = .none,
    extraOAuthParameters: [String: String] = [:],
    oauthNonce: String,
    oauthTimestamp: String
  ) throws(OAuth1Error) -> String {
    let base = try signatureBaseString(
      method: method,
      url: url,
      token: token,
      extraOAuthParameters: extraOAuthParameters,
      oauthNonce: oauthNonce,
      oauthTimestamp: oauthTimestamp
    )
    return sign(baseString: base, tokenSecret: token.secret)
  }

  // MARK: Internals

  /// Builds the full set of `oauth_*` parameters including a freshly computed
  /// signature, using the injected nonce/timestamp.
  private func signedOAuthParameters(
    method: String,
    url: URL,
    token: Token,
    extraOAuthParameters: [String: String]
  ) throws(OAuth1Error) -> [String: String] {
    let nonceValue = nonce()
    let timestampValue = String(Int(timestamp().timeIntervalSince1970))
    var parameters = baseOAuthParameters(
      token: token,
      extraOAuthParameters: extraOAuthParameters,
      nonce: nonceValue,
      timestamp: timestampValue
    )
    let base = try Self.signatureBaseString(
      method: method,
      url: url,
      oauthParameters: parameters,
      queryParameters: Self.queryParameters(from: url)
    )
    parameters["oauth_signature"] = sign(baseString: base, tokenSecret: token.secret)
    return parameters
  }

  /// Assembles the standard `oauth_*` parameters (everything except
  /// `oauth_signature`).
  private func baseOAuthParameters(
    token: Token,
    extraOAuthParameters: [String: String],
    nonce: String,
    timestamp: String
  ) -> [String: String] {
    var parameters: [String: String] = [
      "oauth_consumer_key": consumerKey,
      "oauth_nonce": nonce,
      "oauth_signature_method": "HMAC-SHA1",
      "oauth_timestamp": timestamp,
      "oauth_version": "1.0",
    ]
    if let oauthToken = token.token {
      parameters["oauth_token"] = oauthToken
    }
    for (key, value) in extraOAuthParameters {
      parameters[key] = value
    }
    return parameters
  }

  /// HMAC-SHA1 of `baseString` under `consumerSecret&tokenSecret`, base64-encoded.
  private func sign(baseString: String, tokenSecret: String?) -> String {
    let signingKey =
      "\(Self.percentEncode(consumerSecret))&\(Self.percentEncode(tokenSecret ?? ""))"
    let key = SymmetricKey(data: Data(signingKey.utf8))
    let mac = HMAC<Insecure.SHA1>.authenticationCode(
      for: Data(baseString.utf8),
      using: key
    )
    return Data(mac).base64EncodedString()
  }

  /// Builds the signature base string from the merged, sorted, encoded
  /// parameters per RFC 5849 §3.4.1.
  static func signatureBaseString(
    method: String,
    url: URL,
    oauthParameters: [String: String],
    queryParameters: [(String, String)]
  ) throws(OAuth1Error) -> String {
    guard let baseURL = baseStringURI(from: url) else {
      throw OAuth1Error.invalidURL
    }
    // Merge oauth params with any query params, percent-encode every key/value,
    // then sort by encoded key (and by encoded value to break ties).
    var encoded: [(String, String)] = []
    for (key, value) in oauthParameters {
      encoded.append((percentEncode(key), percentEncode(value)))
    }
    for (key, value) in queryParameters {
      encoded.append((percentEncode(key), percentEncode(value)))
    }
    encoded.sort { lhs, rhs in
      lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0
    }
    let parameterString = encoded
      .map { "\($0.0)=\($0.1)" }
      .joined(separator: "&")
    return [
      method.uppercased(),
      percentEncode(baseURL),
      percentEncode(parameterString),
    ].joined(separator: "&")
  }

  /// The base-string URI per RFC 5849 §3.4.1.2: scheme + authority + path, with
  /// the query and fragment removed and the default port elided.
  static func baseStringURI(from url: URL) -> String? {
    guard
      var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let scheme = components.scheme?.lowercased(),
      let host = components.host?.lowercased()
    else {
      return nil
    }
    components.query = nil
    components.fragment = nil
    var result = "\(scheme)://\(host)"
    if let port = components.port,
      !((scheme == "http" && port == 80) || (scheme == "https" && port == 443)) {
      result += ":\(port)"
    }
    result += components.percentEncodedPath
    return result
  }

  /// Decomposes a URL's query into raw (decoded) name/value pairs to fold into
  /// the signature base string.
  static func queryParameters(from url: URL) -> [(String, String)] {
    guard
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let items = components.queryItems
    else {
      return []
    }
    return items.map { ($0.name, $0.value ?? "") }
  }

  /// Percent-encodes a string per RFC 3986 §2.3, leaving only the unreserved
  /// set literal and uppercasing hex digits.
  static func percentEncode(_ string: String) -> String {
    var allowed = CharacterSet()
    allowed.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    // `addingPercentEncoding` already emits uppercase hex, matching the spec.
    return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
  }

  /// Generates a random hex nonce (16 bytes → 32 hex characters).
  public static func randomNonce() -> String {
    var bytes = [UInt8](repeating: 0, count: 16)
    for index in bytes.indices {
      bytes[index] = UInt8.random(in: .min ... .max)
    }
    return bytes.map { String(format: "%02x", $0) }.joined()
  }
}
