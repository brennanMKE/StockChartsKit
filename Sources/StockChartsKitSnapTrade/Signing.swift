import Crypto
import Foundation

/// An error raised while building a SnapTrade request signature.
///
/// The error space is closed (PRD §14), so the signer is declared with typed
/// `throws(SnapTradeSigningError)`. No case ever carries a secret value.
public enum SnapTradeSigningError: Error, Sendable, Equatable {
  /// The request URL could not be parsed into a path and query.
  case invalidURL
  /// The request body could not be serialized into a canonical JSON object for
  /// inclusion in the signature object.
  case invalidBody
}

/// SnapTrade request signing with HMAC-SHA256, implemented with `swift-crypto`
/// — no third-party signing library (PRD §13).
///
/// ## What is signed
/// Every SnapTrade request carries a `Signature` header. SnapTrade signs a JSON
/// "signature object" describing the request, with the following exact shape and
/// key order:
///
/// ```json
/// {"content":<request body or null>,"path":"<path>","query":"<sorted query>"}
/// ```
///
/// where:
/// - `content` is the parsed JSON request body for `POST`/`PUT` requests, or
///   `null` for bodiless `GET` requests.
/// - `path` is the request path including the `/api/v1` prefix, e.g.
///   `/api/v1/accounts`.
/// - `query` is the URL query string with its parameters sorted by name and
///   percent-encoded (RFC 3986 unreserved set), joined with `&`, e.g.
///   `clientId=abc&timestamp=123&userId=u&userSecret=s`.
///
/// The signature object is serialized to UTF-8 bytes with **sorted keys** and
/// **no insignificant whitespace** (`JSONSerialization` with
/// `.sortedKeys`/`.withoutEscapingSlashes`), then signed:
///
/// ```
/// Signature = base64( HMAC-SHA256( signatureObjectBytes, key = consumerKey ) )
/// ```
///
/// The `consumerKey` is used directly as the HMAC key bytes (UTF-8).
///
/// ## Test-vector caveat
/// There is no widely published official HMAC test vector for SnapTrade's
/// signing scheme, so this implementation documents the exact bytes signed and
/// is validated by (a) determinism — identical inputs always yield an identical
/// signature — and (b) an independently computed `HMAC-SHA256(base64)` over the
/// exact signature-object bytes for a known synthetic key/input. That proves the
/// HMAC wiring is correct even though the canonical server contract cannot be
/// vector-checked offline.
///
/// The timestamp is injectable so tests can pin it and assert an exact signature.
public struct SnapTradeSigner: Sendable {
  /// The developer-app consumer key. Used directly as the HMAC key. Never logged.
  private let consumerKey: String

  /// Creates a signer.
  ///
  /// - Parameter consumerKey: The SnapTrade `consumerKey`, used as the HMAC key.
  ///   Never logged.
  public init(consumerKey: String) {
    self.consumerKey = consumerKey
  }

  // MARK: Signature object

  /// Builds the canonical JSON signature-object bytes for a request.
  ///
  /// Exposed so tests can independently HMAC the exact bytes and compare.
  ///
  /// - Parameters:
  ///   - path: The request path including the `/api/v1` prefix.
  ///   - query: The already-sorted, percent-encoded query string (no leading
  ///     `?`). Pass an empty string when there is no query.
  ///   - body: The raw request body bytes for `POST`/`PUT`, or `nil` for a
  ///     bodiless request. When present it must parse as a JSON object/array.
  /// - Returns: The UTF-8 bytes that are fed to HMAC-SHA256.
  /// - Throws: ``SnapTradeSigningError/invalidBody`` if `body` is not valid JSON.
  public func signatureObjectData(
    path: String,
    query: String,
    body: Data?
  ) throws(SnapTradeSigningError) -> Data {
    // Build the object as a dictionary, then serialize with sorted keys so the
    // byte sequence is fully deterministic.
    var object: [String: Any] = [
      "path": path,
      "query": query,
    ]
    if let body, !body.isEmpty {
      let parsed: Any
      do {
        parsed = try JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed])
      } catch {
        throw SnapTradeSigningError.invalidBody
      }
      object["content"] = parsed
    } else {
      object["content"] = NSNull()
    }

    do {
      return try JSONSerialization.data(
        withJSONObject: object,
        options: [.sortedKeys, .withoutEscapingSlashes]
      )
    } catch {
      throw SnapTradeSigningError.invalidBody
    }
  }

  // MARK: Signing

  /// Computes the base64 `Signature` header value for a request.
  ///
  /// - Parameters:
  ///   - path: The request path including the `/api/v1` prefix.
  ///   - query: The sorted, percent-encoded query string (no leading `?`).
  ///   - body: The raw request body for `POST`/`PUT`, or `nil`.
  /// - Returns: The base64-encoded HMAC-SHA256 digest.
  /// - Throws: ``SnapTradeSigningError/invalidBody`` if `body` is not valid JSON.
  public func signature(
    path: String,
    query: String,
    body: Data? = nil
  ) throws(SnapTradeSigningError) -> String {
    let data = try signatureObjectData(path: path, query: query, body: body)
    let key = SymmetricKey(data: Data(consumerKey.utf8))
    let mac = HMAC<SHA256>.authenticationCode(for: data, using: key)
    return Data(mac).base64EncodedString()
  }

  /// Computes the signature for a fully-formed request URL.
  ///
  /// Splits the URL into its path and query, sorts/encodes the query, and signs.
  ///
  /// - Parameters:
  ///   - url: The full request URL, including any query items.
  ///   - body: The raw request body for `POST`/`PUT`, or `nil`.
  /// - Returns: The base64-encoded HMAC-SHA256 digest.
  /// - Throws: ``SnapTradeSigningError/invalidURL`` if the URL has no path, or
  ///   ``SnapTradeSigningError/invalidBody`` for a malformed body.
  public func signature(
    for url: URL,
    body: Data? = nil
  ) throws(SnapTradeSigningError) -> String {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      throw SnapTradeSigningError.invalidURL
    }
    let path = components.percentEncodedPath
    guard !path.isEmpty else { throw SnapTradeSigningError.invalidURL }
    let query = Self.canonicalQuery(from: components.queryItems ?? [])
    return try signature(path: path, query: query, body: body)
  }

  // MARK: Query canonicalization

  /// Builds the canonical query string: parameters sorted by name (ties broken
  /// by value), each name and value percent-encoded per RFC 3986, joined by `&`.
  public static func canonicalQuery(from items: [URLQueryItem]) -> String {
    let encoded: [(String, String)] = items.map { item in
      (percentEncode(item.name), percentEncode(item.value ?? ""))
    }
    let sorted = encoded.sorted { lhs, rhs in
      lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0
    }
    let pairs: [String] = sorted.map { pair in
      "\(pair.0)=\(pair.1)"
    }
    return pairs.joined(separator: "&")
  }

  /// Percent-encodes a string per RFC 3986 §2.3, leaving only the unreserved
  /// set literal and uppercasing hex digits.
  public static func percentEncode(_ string: String) -> String {
    var allowed = CharacterSet()
    allowed.insert(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )
    return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
  }
}
