import Foundation
import StockChartsKit

/// The persisted OAuth 1.0a access-token pair for an E*Trade connection.
///
/// Stored as a single JSON item in the ``TokenStore`` keyed by
/// `"etrade.<connectionID>"`. Never logged.
///
/// E*Trade access tokens expire at **midnight US Eastern** (not after a fixed
/// TTL) and become inactive after two hours of inactivity. There is no
/// `expiresAt` instant the issuer hands back, so the provider does not track one
/// here; an expired/inactive token surfaces as an HTTP error on use and is
/// recovered by `GET /oauth/renew_access_token` (see ``ETradeProvider``).
struct ETradeTokenBundle: Codable, Sendable {
  /// The OAuth access token (`oauth_token`).
  var token: String
  /// The OAuth access-token secret used in the signing key.
  var secret: String
}

// MARK: - Wire types

/// The `/v1/accounts/list.json` response envelope.
///
/// E*Trade nests responses under PascalCase keys (`AccountListResponse`,
/// `Accounts`, `Account`), which the shared decoder's `.convertFromSnakeCase`
/// strategy does not touch — so each PascalCase wire key is mapped explicitly.
struct ETradeAccountListResponse: Decodable, Sendable {
  struct AccountListResponse: Decodable, Sendable {
    let accounts: Accounts
    enum CodingKeys: String, CodingKey { case accounts = "Accounts" }
  }
  struct Accounts: Decodable, Sendable {
    let account: [WireAccount]
    enum CodingKeys: String, CodingKey { case account = "Account" }
  }
  let accountListResponse: AccountListResponse
  enum CodingKeys: String, CodingKey { case accountListResponse = "AccountListResponse" }
}

/// A single account in the accounts list.
///
/// E*Trade distinguishes `accountId` (the human-facing number) from
/// `accountIdKey` (an opaque key used in portfolio/balance paths). The provider
/// keys reads on `accountIdKey`.
struct WireAccount: Decodable, Sendable {
  let accountId: String
  let accountIdKey: String
  let accountName: String?
  let accountType: String?
  let institutionType: String?
}

/// The `/v1/accounts/{accountIdKey}/portfolio.json` response envelope.
struct ETradePortfolioResponse: Decodable, Sendable {
  struct PortfolioResponse: Decodable, Sendable {
    let accountPortfolio: [AccountPortfolio]
    enum CodingKeys: String, CodingKey { case accountPortfolio = "AccountPortfolio" }
  }
  struct AccountPortfolio: Decodable, Sendable {
    let position: [WirePosition]?
    enum CodingKeys: String, CodingKey { case position = "Position" }
  }
  let portfolioResponse: PortfolioResponse
  enum CodingKeys: String, CodingKey { case portfolioResponse = "PortfolioResponse" }
}

/// A single portfolio position.
struct WirePosition: Decodable, Sendable {
  struct Product: Decodable, Sendable {
    let symbol: String
    let securityType: String?
  }
  let product: Product
  let quantity: Decimal?
  let pricePaid: Decimal?
  let marketValue: Decimal?
  let totalGain: Decimal?
  enum CodingKeys: String, CodingKey {
    case product = "Product"
    case quantity, pricePaid, marketValue, totalGain
  }
}

/// The `/v1/accounts/{accountIdKey}/balance.json` response envelope.
struct ETradeBalanceResponse: Decodable, Sendable {
  struct BalanceResponse: Decodable, Sendable {
    let accountId: String?
    let computed: Computed?
    enum CodingKeys: String, CodingKey {
      case accountId
      case computed = "Computed"
    }
  }
  struct Computed: Decodable, Sendable {
    let realTimeValues: RealTimeValues?
    let cashBalance: Decimal?
    let cashAvailableForInvestment: Decimal?
    let marginBuyingPower: Decimal?
    let cashBuyingPower: Decimal?
    enum CodingKeys: String, CodingKey {
      case realTimeValues = "RealTimeValues"
      case cashBalance, cashAvailableForInvestment, marginBuyingPower, cashBuyingPower
    }
  }
  struct RealTimeValues: Decodable, Sendable {
    let totalAccountValue: Decimal?
  }
  let balanceResponse: BalanceResponse
  enum CodingKeys: String, CodingKey { case balanceResponse = "BalanceResponse" }
}

/// The `/v1/market/quote/{symbol}.json` response envelope.
struct ETradeQuoteResponse: Decodable, Sendable {
  struct QuoteResponse: Decodable, Sendable {
    let quoteData: [QuoteData]
    enum CodingKeys: String, CodingKey { case quoteData = "QuoteData" }
  }
  struct QuoteData: Decodable, Sendable {
    let all: AllQuote?
    let product: Product?
    enum CodingKeys: String, CodingKey {
      case all = "All"
      case product = "Product"
    }
  }
  struct AllQuote: Decodable, Sendable {
    let lastTrade: Decimal?
    let previousClose: Decimal?
  }
  struct Product: Decodable, Sendable {
    let symbol: String?
  }
  let quoteResponse: QuoteResponse
  enum CodingKeys: String, CodingKey { case quoteResponse = "QuoteResponse" }
}
