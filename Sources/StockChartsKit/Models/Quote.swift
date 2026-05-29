import Foundation

/// A current quote for a symbol.
public struct Quote: Hashable, Sendable, Codable {
  /// The quoted symbol.
  public let symbol: Symbol
  /// The last traded price.
  public let last: Money
  /// The previous close, if available.
  public let previousClose: Money?
  /// When this quote was observed.
  public let asOf: Date

  /// Creates a quote.
  public init(
    symbol: Symbol,
    last: Money,
    previousClose: Money?,
    asOf: Date
  ) {
    self.symbol = symbol
    self.last = last
    self.previousClose = previousClose
    self.asOf = asOf
  }
}
