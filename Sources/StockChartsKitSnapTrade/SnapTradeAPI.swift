import Foundation
import StockChartsKit

/// Low-level builder for signed SnapTrade requests, shared by the registration
/// flow, `discover()`, and the per-connection provider.
///
/// Every SnapTrade request carries `clientId`, `userId`, `userSecret`, and a
/// `timestamp` as query parameters, plus a `Signature` header computed by
/// ``SnapTradeSigner`` over the canonical signature object. This type assembles
/// those query parameters and the signed request in one place so the call sites
/// stay small.
///
/// Credentials are held only for the lifetime of a request build and are never
/// logged.
struct SnapTradeAPI: Sendable {
  /// The production API base, `https://api.snaptrade.com/api/v1`.
  static let base = "https://api.snaptrade.com/api/v1"

  /// The path prefix included in the signed `path`, `/api/v1`.
  static let pathPrefix = "/api/v1"

  let clientID: String
  let signer: SnapTradeSigner
  /// Supplies the request timestamp (seconds since epoch). Injectable for tests.
  let timestamp: @Sendable () -> Int

  init(
    clientID: String,
    consumerKey: String,
    timestamp: @escaping @Sendable () -> Int = { Int(Date().timeIntervalSince1970) }
  ) {
    self.clientID = clientID
    self.signer = SnapTradeSigner(consumerKey: consumerKey)
    self.timestamp = timestamp
  }

  /// Builds a signed `URLRequest` for `path` (relative to `/api/v1`, e.g.
  /// `/accounts`).
  ///
  /// - Parameters:
  ///   - method: HTTP method, e.g. `"GET"` or `"POST"`.
  ///   - path: The path relative to `/api/v1`, with a leading slash.
  ///   - credentials: The per-user `userId`/`userSecret`, or `nil` for
  ///     registration calls that authenticate with only `clientId`.
  ///   - extraQuery: Additional query items appended before signing.
  ///   - body: The JSON request body for `POST`/`PUT`, or `nil`.
  /// - Throws: ``BrokerageError`` if the URL cannot be formed, or wraps a
  ///   ``SnapTradeSigningError`` as ``BrokerageError/network(underlying:)``.
  func signedRequest(
    method: String,
    path: String,
    credentials: SnapTradeUserCredentials?,
    extraQuery: [URLQueryItem] = [],
    body: Data? = nil
  ) throws -> URLRequest {
    var items: [URLQueryItem] = [
      URLQueryItem(name: "clientId", value: clientID),
      URLQueryItem(name: "timestamp", value: String(timestamp())),
    ]
    if let credentials {
      items.append(URLQueryItem(name: "userId", value: credentials.userId))
      items.append(URLQueryItem(name: "userSecret", value: credentials.userSecret))
    }
    items.append(contentsOf: extraQuery)

    let signedPath = Self.pathPrefix + path
    let canonicalQuery = SnapTradeSigner.canonicalQuery(from: items)

    let signature: String
    do {
      signature = try signer.signature(path: signedPath, query: canonicalQuery, body: body)
    } catch {
      throw BrokerageError.network(underlying: error)
    }

    var components = URLComponents(string: "\(Self.base)\(path)")
    // Use the canonical (sorted, encoded) query so the wire request matches the
    // exact string that was signed.
    components?.percentEncodedQuery = canonicalQuery
    guard let url = components?.url else {
      throw BrokerageError.network(underlying: URLError(.badURL))
    }

    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue(signature, forHTTPHeaderField: "Signature")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let body {
      request.httpBody = body
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    return request
  }
}

extension ProviderID {
  /// Derives a namespaced SnapTrade provider id from a brokerage name, e.g.
  /// `"Fidelity NetBenefits"` → `ProviderID("snaptrade.fidelity-netbenefits")`.
  ///
  /// The slug lowercases the name, replaces any run of non-alphanumeric
  /// characters with a single hyphen, and trims leading/trailing hyphens.
  static func snapTrade(brokerageName: String) -> ProviderID {
    ProviderID(rawValue: "snaptrade.\(slugify(brokerageName))")
  }

  /// Slugifies a brokerage name for use in a provider id.
  static func slugify(_ name: String) -> String {
    let lowered = name.lowercased()
    var slug = ""
    var lastWasHyphen = false
    for scalar in lowered.unicodeScalars {
      if CharacterSet.alphanumerics.contains(scalar) {
        slug.unicodeScalars.append(scalar)
        lastWasHyphen = false
      } else if !lastWasHyphen {
        slug.append("-")
        lastWasHyphen = true
      }
    }
    while slug.hasPrefix("-") { slug.removeFirst() }
    while slug.hasSuffix("-") { slug.removeLast() }
    return slug.isEmpty ? "unknown" : slug
  }
}
