import Foundation
import StockChartsKit

/// Wire types decoded from SnapTrade's JSON responses.
///
/// These mirror only the fields the package reads; SnapTrade returns many more.
/// All money/quantity fields use ``Decimal`` (never `Double`) per PRD §14. The
/// shared ``HTTPClient`` decoder converts snake_case keys to camelCase and
/// tolerates `Decimal` values supplied as JSON numbers or numeric strings.

// MARK: registerUser

/// The response from `POST /api/v1/snapTrade/registerUser`.
struct SnapTradeRegisterUserResponse: Decodable, Sendable {
  let userId: String
  let userSecret: String
}

// MARK: login

/// The response from `POST /api/v1/snapTrade/login`.
///
/// SnapTrade returns a `redirectURI` pointing at the hosted connection portal.
struct SnapTradeLoginResponse: Decodable, Sendable {
  let redirectURI: String
}

// MARK: Accounts

/// A SnapTrade account as returned by `GET /accounts`.
struct SnapTradeAccount: Decodable, Sendable {
  let id: String
  let name: String?
  let number: String?
  /// The currency code of the account's balance, when present.
  let currency: SnapTradeCurrency?
  /// The brokerage authorization this account belongs to — the basis for the
  /// per-connection grouping and the namespaced provider id.
  let brokerageAuthorization: SnapTradeBrokerageAuthorization?
}

/// A reference to the connection (brokerage authorization) backing an account.
///
/// SnapTrade may return this as either an embedded object (carrying the
/// brokerage name) or a bare id string; both shapes decode here.
struct SnapTradeBrokerageAuthorization: Decodable, Sendable {
  let id: String
  /// The human brokerage name, e.g. `"Robinhood"`, `"Fidelity"`.
  let brokerageName: String?

  private enum CodingKeys: String, CodingKey {
    case id
    case brokerage
    case name
  }

  private enum BrokerageKeys: String, CodingKey {
    case name
    case displayName
    case slug
  }

  init(from decoder: any Decoder) throws {
    // Embedded-object form: {"id": "...", "brokerage": {"name": "Robinhood"}}.
    if let container = try? decoder.container(keyedBy: CodingKeys.self),
      container.contains(.id) {
      id = try container.decode(String.self, forKey: .id)
      if let brokerage = try? container.nestedContainer(
        keyedBy: BrokerageKeys.self,
        forKey: .brokerage
      ) {
        brokerageName =
          (try? brokerage.decodeIfPresent(String.self, forKey: .name))
          ?? (try? brokerage.decodeIfPresent(String.self, forKey: .displayName))
          ?? (try? brokerage.decodeIfPresent(String.self, forKey: .slug))
          ?? nil
      } else {
        // Some payloads put the brokerage name directly on the authorization.
        brokerageName = try container.decodeIfPresent(String.self, forKey: .name)
      }
      return
    }
    // Bare-string form: "f9e8...".
    let single = try decoder.singleValueContainer()
    id = try single.decode(String.self)
    brokerageName = nil
  }
}

/// A currency reference embedded in account/balance payloads.
struct SnapTradeCurrency: Decodable, Sendable {
  let code: String
}

// MARK: Balances

/// One balance entry from `GET /accounts/{id}/balances`.
///
/// SnapTrade returns an array (one per currency); the package reads the first
/// entry, or the account's base currency when present.
struct SnapTradeBalance: Decodable, Sendable {
  let currency: SnapTradeCurrency?
  /// Decimal values may arrive as JSON numbers or numeric strings.
  let cash: LossyDecimal?
  let buyingPower: LossyDecimal?
}

// MARK: Positions

/// One holding from `GET /accounts/{id}/positions`.
struct SnapTradePosition: Decodable, Sendable {
  let symbol: SnapTradePositionSymbol?
  /// Decimal values may arrive as JSON numbers or numeric strings.
  let units: LossyDecimal?
  let price: LossyDecimal?
  let averagePurchasePrice: LossyDecimal?
  let openPnl: LossyDecimal?
}

/// The symbol envelope SnapTrade nests inside a position.
struct SnapTradePositionSymbol: Decodable, Sendable {
  let symbol: SnapTradeSymbolDetail?
}

/// The innermost symbol detail.
struct SnapTradeSymbolDetail: Decodable, Sendable {
  let symbol: String?
  let type: SnapTradeSymbolType?
  let currency: SnapTradeCurrency?
}

/// A symbol's instrument type, used to map to ``AssetClass``.
struct SnapTradeSymbolType: Decodable, Sendable {
  let code: String?
}
