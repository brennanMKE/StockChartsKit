import Foundation

/// A stable, provider-scoped account identifier.
public struct AccountID: RawRepresentable, Hashable, Sendable, Codable {
  /// The raw identifier value.
  public let rawValue: String

  /// Creates an account identifier from its raw value.
  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}

/// An identifier for a brokerage provider, e.g. `"etrade"`,
/// `"coinbase"`, `"snaptrade.robinhood"`.
public struct ProviderID: RawRepresentable, Hashable, Sendable, Codable {
  /// The raw identifier value.
  public let rawValue: String

  /// Creates a provider identifier from its raw value.
  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}

/// An identifier that groups accounts sharing a single authentication.
public struct ConnectionID: RawRepresentable, Hashable, Sendable, Codable {
  /// The raw identifier value.
  public let rawValue: String

  /// Creates a connection identifier from its raw value.
  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}

/// The kind of account, used for grouping and display.
public enum AccountKind: String, Sendable, Codable {
  case brokerage, margin, ira, rothIRA, traditional401k, roth401k,
    hsa, fhsa, esa, custodial, crypto, retirement, savings, other
}

/// A single brokerage account.
public struct Account: Identifiable, Hashable, Sendable, Codable {
  /// A stable, provider-scoped identifier.
  public let id: AccountID
  /// The provider that owns this account.
  public let providerID: ProviderID
  /// A human-readable name for UI, e.g. `"E*Trade Brokerage 1234"`.
  public let displayName: String
  /// The kind of account.
  public let kind: AccountKind
  /// The account's base currency.
  public let baseCurrency: CurrencyCode
  /// Groups accounts that share one authentication, if any.
  public let connectionID: ConnectionID?

  /// Creates an account.
  public init(
    id: AccountID,
    providerID: ProviderID,
    displayName: String,
    kind: AccountKind,
    baseCurrency: CurrencyCode,
    connectionID: ConnectionID?
  ) {
    self.id = id
    self.providerID = providerID
    self.displayName = displayName
    self.kind = kind
    self.baseCurrency = baseCurrency
    self.connectionID = connectionID
  }
}
