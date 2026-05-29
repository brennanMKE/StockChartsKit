import Foundation

/// A property wrapper that decodes a `Decimal` from either a JSON number or a
/// numeric JSON string, preserving full precision.
///
/// Many brokerage APIs serialize money and quantity values as strings (e.g.
/// `"123.45"`) to avoid binary floating-point loss in the JSON layer. Swift's
/// `JSONDecoder` has no built-in strategy that accepts a `Decimal` in both
/// forms, so model fields opt in by annotating their property:
///
/// ```swift
/// struct Balance: Decodable {
///   @LossyDecimal var amount: Decimal
/// }
/// ```
///
/// ## Precision
/// String values are parsed through `Decimal(string:)` with the POSIX locale,
/// which performs an exact base-10 parse — never via `Double` — so a value like
/// `"0.1"` decodes to exactly `0.1`. Numeric JSON values are decoded directly as
/// `Decimal`, which `JSONDecoder` also reads from the underlying base-10 token
/// without an intermediate `Double`.
@propertyWrapper
public struct LossyDecimal: Sendable, Hashable {
  /// The wrapped decimal value.
  public var wrappedValue: Decimal

  /// Wraps an existing decimal value.
  public init(wrappedValue: Decimal) {
    self.wrappedValue = wrappedValue
  }
}

extension LossyDecimal: Decodable {
  /// Decodes from a JSON number or a numeric JSON string.
  ///
  /// - Throws: `DecodingError.dataCorrupted` if a string value is not a valid
  ///   base-10 decimal.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let value = try? container.decode(Decimal.self) {
      wrappedValue = value
      return
    }
    let raw = try container.decode(String.self)
    guard let value = Decimal(string: raw, locale: Self.posix) else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Not a valid decimal string: \(raw)"
      )
    }
    wrappedValue = value
  }

  private static let posix = Locale(identifier: "en_US_POSIX")
}

extension LossyDecimal: Encodable {
  /// Encodes as a JSON number.
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(wrappedValue)
  }
}

extension KeyedDecodingContainer {
  /// Decodes an optional ``LossyDecimal``, treating a missing key or JSON null
  /// as `nil` rather than throwing.
  public func decode(
    _ type: LossyDecimal?.Type,
    forKey key: Key
  ) throws -> LossyDecimal? {
    try decodeIfPresent(LossyDecimal.self, forKey: key)
  }
}
