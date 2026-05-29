import Foundation

/// A canonical ticker symbol, e.g. `"AMD"`, `"BTC-USD"`, `"VFFSX"`.
public struct Symbol: RawRepresentable, Hashable, Sendable, Codable {
  /// The raw ticker value.
  public let rawValue: String

  /// Creates a symbol from its raw value.
  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}

/// The asset class of a position.
public enum AssetClass: String, Sendable, Codable {
  case equity, etf, mutualFund, option, bond, crypto, cash, other
}

/// A holding within an account as of a point in time.
public struct Position: Hashable, Sendable, Codable {
  /// The account that holds this position.
  public let accountID: AccountID
  /// The canonical ticker symbol.
  public let symbol: Symbol
  /// The asset class.
  public let assetClass: AssetClass
  /// The quantity held; may be fractional.
  public let quantity: Decimal
  /// The average cost per unit, or `nil` if unknown.
  public let averageCost: Money?
  /// The current market value (quantity × last price).
  public let marketValue: Money
  /// The unrealized profit or loss, or `nil` if unknown.
  public let unrealizedPL: Money?
  /// When this snapshot was taken.
  public let asOf: Date

  /// Creates a position.
  public init(
    accountID: AccountID,
    symbol: Symbol,
    assetClass: AssetClass,
    quantity: Decimal,
    averageCost: Money?,
    marketValue: Money,
    unrealizedPL: Money?,
    asOf: Date
  ) {
    self.accountID = accountID
    self.symbol = symbol
    self.assetClass = assetClass
    self.quantity = quantity
    self.averageCost = averageCost
    self.marketValue = marketValue
    self.unrealizedPL = unrealizedPL
    self.asOf = asOf
  }
}
