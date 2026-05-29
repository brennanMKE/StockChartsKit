import Foundation

/// A recorded HTTP response replayed by ``ReplayURLProtocol``.
///
/// Fixtures are stored on disk as JSON under a test target's `Fixtures/`
/// directory (see ``FixtureStore`` for the layout). The on-disk shape mirrors
/// this type: a status, optional headers, and a body that is either inline
/// JSON or a reference to a sibling file.
public struct HTTPFixture: Sendable, Codable {
  /// The HTTP status code to return. Defaults to `200`.
  public var statusCode: Int

  /// Response headers to return. Defaults to `Content-Type: application/json`.
  public var headers: [String: String]

  /// The response body. Empty when the fixture models a bodiless response.
  public var body: Data

  /// Creates a fixture from explicit parts.
  public init(
    statusCode: Int = 200,
    headers: [String: String] = ["Content-Type": "application/json"],
    body: Data = Data()
  ) {
    self.statusCode = statusCode
    self.headers = headers
    self.body = body
  }

  // MARK: Codable

  private enum CodingKeys: String, CodingKey {
    case statusCode, headers, body, bodyJSON
  }

  /// Decodes a fixture.
  ///
  /// The `body` may be supplied either as a base64 `body` string or, more
  /// conveniently for hand-authored JSON fixtures, as an inline `bodyJSON`
  /// object/array that is re-encoded to UTF-8 bytes.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    statusCode = try container.decodeIfPresent(Int.self, forKey: .statusCode) ?? 200
    headers =
      try container.decodeIfPresent([String: String].self, forKey: .headers)
      ?? ["Content-Type": "application/json"]
    if let raw = try container.decodeIfPresent(Data.self, forKey: .body) {
      body = raw
    } else if container.contains(.bodyJSON) {
      let json = try container.decode(JSONValue.self, forKey: .bodyJSON)
      body = try JSONEncoder().encode(json)
    } else {
      body = Data()
    }
  }

  /// Encodes a fixture, emitting the body as base64 `body`.
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(statusCode, forKey: .statusCode)
    try container.encode(headers, forKey: .headers)
    try container.encode(body, forKey: .body)
  }
}

/// A minimal JSON value used to embed an inline response body in a fixture file
/// via the `bodyJSON` key. Re-encoded verbatim to produce the replayed body.
enum JSONValue: Sendable, Codable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else if let value = try? container.decode([String: JSONValue].self) {
      self = .object(value)
    } else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Unsupported JSON value"
      )
    }
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }
}
