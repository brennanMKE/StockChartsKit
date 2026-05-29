import Foundation

/// A point-in-time balance summary for an account.
public struct Balance: Hashable, Sendable, Codable {
  /// The account this balance describes.
  public let accountID: AccountID
  /// The total account value.
  public let total: Money
  /// Settled cash.
  public let cash: Money
  /// Buying power, if the provider exposes it.
  public let buyingPower: Money?
  /// When this balance was observed.
  public let asOf: Date

  /// Creates a balance.
  public init(
    accountID: AccountID,
    total: Money,
    cash: Money,
    buyingPower: Money?,
    asOf: Date
  ) {
    self.accountID = accountID
    self.total = total
    self.cash = cash
    self.buyingPower = buyingPower
    self.asOf = asOf
  }
}
