import Foundation

/// An ISO 4217-style currency code (e.g. `"USD"`, `"EUR"`) extended to cover
/// crypto assets such as `"BTC"` or `"ETH"`.
///
/// The raw value is always stored uppercased, so `CurrencyCode(rawValue: "usd")`
/// and `CurrencyCode(rawValue: "USD")` compare equal.
public struct CurrencyCode: RawRepresentable, Hashable, Sendable, Codable {
  /// The uppercased currency code, e.g. `"USD"`, `"BTC"`.
  public let rawValue: String

  /// Creates a currency code, uppercasing the supplied raw value.
  public init(rawValue: String) {
    self.rawValue = rawValue.uppercased()
  }

  /// The US dollar (`"USD"`).
  public static let usd = CurrencyCode(rawValue: "USD")
}

/// A monetary amount paired with its currency.
///
/// `Money` backs every monetary value in the package and uses
/// `Foundation.Decimal` for exact base-10 arithmetic — never `Double`.
///
/// ## Rounding
/// `Money` keeps full `Decimal` precision and never rounds internally.
/// Rounding to a currency's minor units (2 for USD, more for crypto) is a
/// presentation concern handled by the host at display time. Equality and
/// hashing are on the exact stored `Decimal`.
public struct Money: Hashable, Sendable, Codable {
  /// The amount, stored with full `Decimal` precision.
  public let amount: Decimal
  /// The currency the amount is expressed in.
  public let currency: CurrencyCode

  /// Creates a money value. The currency defaults to ``CurrencyCode/usd``.
  public init(_ amount: Decimal, _ currency: CurrencyCode = .usd) {
    self.amount = amount
    self.currency = currency
  }

  /// Convenience factory for a US-dollar amount.
  public static func usd(_ amount: Decimal) -> Money {
    Money(amount, .usd)
  }

  /// A zero US-dollar amount, useful as an additive identity.
  public static let zero: Money = .usd(0)

  /// Adds two money values.
  /// - Throws: ``BrokerageError/currencyMismatch(lhs:rhs:)`` when the operands
  ///   use different currencies.
  public static func + (lhs: Money, rhs: Money) throws -> Money {
    guard lhs.currency == rhs.currency else {
      throw BrokerageError.currencyMismatch(lhs: lhs.currency, rhs: rhs.currency)
    }
    return Money(lhs.amount + rhs.amount, lhs.currency)
  }

  /// Subtracts one money value from another.
  /// - Throws: ``BrokerageError/currencyMismatch(lhs:rhs:)`` when the operands
  ///   use different currencies.
  public static func - (lhs: Money, rhs: Money) throws -> Money {
    guard lhs.currency == rhs.currency else {
      throw BrokerageError.currencyMismatch(lhs: lhs.currency, rhs: rhs.currency)
    }
    return Money(lhs.amount - rhs.amount, lhs.currency)
  }

  /// Scales a money value by a `Decimal` factor, preserving full precision.
  public static func * (lhs: Money, rhs: Decimal) -> Money {
    Money(lhs.amount * rhs, lhs.currency)
  }
}
