import Foundation
import os

/// A foreign-exchange rate source used by ``PortfolioAggregator`` to convert
/// monetary values when summing balances or histories across currencies.
///
/// A conformance returns the multiplicative rate that converts an amount
/// expressed in `from` into `to`: `amount(in: to) = amount(in: from) * rate`.
/// Same-currency conversions return `1`.
public protocol FXService: Sendable {
  /// The rate that converts one unit of `from` into `to`, as of `date`.
  ///
  /// - Parameters:
  ///   - from: The source currency.
  ///   - to: The target currency.
  ///   - date: The point in time the rate should reflect. Implementations that
  ///     cannot resolve a historical rate may return the latest available rate
  ///     (see ``ECBFXService`` for its precision caveats).
  /// - Returns: The conversion factor; `1` when `from == to`.
  /// - Throws: A ``BrokerageError`` when a currency cannot be resolved.
  func rate(from: CurrencyCode, to: CurrencyCode, at date: Date) async throws -> Decimal
}

extension FXService {
  /// Converts `money` into `currency` as of `date`, applying ``rate(from:to:at:)``.
  ///
  /// A convenience for callers that hold a ``Money`` rather than a bare amount.
  /// Preserves full `Decimal` precision (no rounding).
  public func convert(
    _ money: Money,
    to currency: CurrencyCode,
    at date: Date = .now
  ) async throws -> Money {
    if money.currency == currency { return money }
    let factor = try await rate(from: money.currency, to: currency, at: date)
    return Money(money.amount * factor, currency)
  }
}

/// The default concrete ``FXService``: European Central Bank reference rates for
/// fiat, with a Coinbase spot-price fallback for crypto.
///
/// ## Fiat (ECB)
/// The ECB publishes free, no-auth daily reference rates as **XML** at
/// `https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml`. The feed is
/// EUR-based: it gives `EUR -> X` for each listed currency. A cross rate is
/// computed through EUR, e.g. `USD -> GBP = (EUR -> GBP) / (EUR -> USD)`.
/// `EUR -> X` and `X -> EUR` are read (or inverted) directly.
///
/// ## Crypto (Coinbase)
/// Currencies the ECB feed does not list (e.g. `BTC`, `ETH`) are resolved with
/// Coinbase's public spot-price endpoint
/// (`https://api.coinbase.com/v2/prices/{base}-{quote}/spot`), which returns the
/// price of one unit of `base` in `quote` as JSON.
///
/// ## `at date:` precision
/// The daily-reference XML carries only the latest published rates, so this
/// service ignores `date` and returns the latest rate. Historical precision is
/// limited to what the endpoint provides. A future enhancement could parse the
/// ECB 90-day (`eurofxref-hist-90d.xml`) or full-history file to honor `date`.
///
/// ## Caching
/// Fetched ECB tables and Coinbase spot prices are cached in an internal actor
/// for ``cacheTTL`` (default one hour) to avoid refetching on every conversion.
///
/// ## Networking injection
/// Both endpoints are reached through an injected ``HTTPClient`` (built over a
/// `URLSession`), so tests supply a replay session and never touch the live
/// network.
public struct ECBFXService: FXService {
  /// The ECB daily reference-rates XML endpoint.
  public static let ecbDailyURL = URL(
    string: "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml"
  )!

  /// The Coinbase spot-price endpoint base.
  public static let coinbaseSpotBase = URL(
    string: "https://api.coinbase.com/v2/prices"
  )!

  /// The euro currency code, the pivot for ECB cross rates.
  private static let eur = CurrencyCode(rawValue: "EUR")

  private let client: HTTPClient
  private let cache: RateCache
  private let cacheTTL: TimeInterval
  private let now: @Sendable () -> Date
  private let logger = Logger(
    subsystem: "co.sstools.stockchartskit",
    category: "FXService"
  )

  /// Creates a service.
  ///
  /// - Parameters:
  ///   - session: The session used for both endpoints. Inject a replay session
  ///     in tests; defaults to `URLSession.shared`.
  ///   - cacheTTL: How long a fetched ECB table or spot price stays fresh.
  ///     Defaults to one hour.
  ///   - now: Supplies the current date for cache expiry. Defaults to `Date.init`.
  public init(
    session: URLSession = .shared,
    cacheTTL: TimeInterval = 3600,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.client = HTTPClient(
      providerID: ProviderID(rawValue: "fx"),
      session: session
    )
    self.cache = RateCache()
    self.cacheTTL = cacheTTL
    self.now = now
  }

  // MARK: FXService

  public func rate(
    from: CurrencyCode,
    to: CurrencyCode,
    at date: Date
  ) async throws -> Decimal {
    if from == to { return 1 }

    // Try fiat via the ECB EUR-based table first.
    let table = try await ecbTable()
    if let rate = Self.fiatCrossRate(from: from, to: to, table: table) {
      return rate
    }

    // Fall back to Coinbase spot for crypto / unlisted pairs.
    return try await coinbaseRate(from: from, to: to)
  }

  // MARK: ECB fiat

  /// Returns `EUR -> X` factors keyed by currency, fetching and caching the
  /// daily XML once per ``cacheTTL``.
  private func ecbTable() async throws -> [CurrencyCode: Decimal] {
    if let cached = await cache.ecbTable(freshAsOf: now(), ttl: cacheTTL) {
      return cached
    }
    let request = URLRequest(url: Self.ecbDailyURL)
    let data = try await client.send(request)
    let parsed = try Self.parseECBXML(data)
    await cache.storeECBTable(parsed, asOf: now())
    return parsed
  }

  /// Computes a fiat cross rate from an EUR-based `table`, or `nil` when either
  /// side is absent (signalling a crypto/unlisted pair to try via Coinbase).
  ///
  /// `EUR` is the pivot: `from -> to = (EUR -> to) / (EUR -> from)`, with
  /// `EUR -> EUR == 1`.
  static func fiatCrossRate(
    from: CurrencyCode,
    to: CurrencyCode,
    table: [CurrencyCode: Decimal]
  ) -> Decimal? {
    let eurToFrom: Decimal
    if from == eur {
      eurToFrom = 1
    } else if let value = table[from] {
      eurToFrom = value
    } else {
      return nil
    }

    let eurToTo: Decimal
    if to == eur {
      eurToTo = 1
    } else if let value = table[to] {
      eurToTo = value
    } else {
      return nil
    }

    guard eurToFrom != 0 else { return nil }
    return eurToTo / eurToFrom
  }

  /// Parses the ECB daily reference-rates XML into an `EUR -> X` table.
  ///
  /// The feed nests `<Cube currency="USD" rate="1.08"/>` elements; every such
  /// element contributes one `EUR -> currency` factor.
  ///
  /// - Throws: ``BrokerageError/decodingFailed(underlying:)`` if the XML cannot
  ///   be parsed or contains no rate elements.
  static func parseECBXML(_ data: Data) throws -> [CurrencyCode: Decimal] {
    let parser = XMLParser(data: data)
    let delegate = ECBXMLDelegate()
    parser.delegate = delegate
    guard parser.parse(), !delegate.rates.isEmpty else {
      throw BrokerageError.decodingFailed(
        underlying: parser.parserError ?? ECBParseError.noRates
      )
    }
    return delegate.rates
  }

  // MARK: Coinbase crypto

  /// Returns the spot price of one unit of `from` in `to` via Coinbase, caching
  /// the result per ``cacheTTL``.
  private func coinbaseRate(
    from: CurrencyCode,
    to: CurrencyCode
  ) async throws -> Decimal {
    let pair = "\(from.rawValue)-\(to.rawValue)"
    if let cached = await cache.spot(pair: pair, freshAsOf: now(), ttl: cacheTTL) {
      return cached
    }
    let url = Self.coinbaseSpotBase
      .appendingPathComponent(pair)
      .appendingPathComponent("spot")
    let request = URLRequest(url: url)
    let response: CoinbaseSpotResponse
    do {
      response = try await client.send(request, expecting: CoinbaseSpotResponse.self)
    } catch let error as BrokerageError {
      // A 4xx (unknown pair) means we cannot resolve this currency at all.
      if case .providerError = error {
        throw BrokerageError.currencyMismatch(lhs: from, rhs: to)
      }
      throw error
    }
    guard let amount = Decimal(string: response.data.amount, locale: Self.posix) else {
      throw BrokerageError.decodingFailed(underlying: ECBParseError.badSpotAmount)
    }
    await cache.storeSpot(amount, pair: pair, asOf: now())
    return amount
  }

  private static let posix = Locale(identifier: "en_US_POSIX")
}

/// The Coinbase `/v2/prices/{pair}/spot` response shape.
private struct CoinbaseSpotResponse: Decodable {
  struct Payload: Decodable {
    let amount: String
    let base: String
    let currency: String
  }
  let data: Payload
}

/// Errors raised while parsing FX source documents.
enum ECBParseError: Error, Sendable {
  /// The ECB XML parsed but contained no `<Cube currency=.. rate=..>` elements.
  case noRates
  /// A Coinbase spot amount was not a valid decimal string.
  case badSpotAmount
}

/// A `XMLParser` delegate that collects `EUR -> currency` rates from the ECB
/// daily reference-rates document.
private final class ECBXMLDelegate: NSObject, XMLParserDelegate {
  /// The accumulated `EUR -> X` factors.
  private(set) var rates: [CurrencyCode: Decimal] = [:]
  private static let posix = Locale(identifier: "en_US_POSIX")

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String]
  ) {
    guard elementName == "Cube" else { return }
    guard
      let currency = attributeDict["currency"],
      let rawRate = attributeDict["rate"],
      let rate = Decimal(string: rawRate, locale: Self.posix)
    else { return }
    rates[CurrencyCode(rawValue: currency)] = rate
  }
}

/// A small actor caching the ECB rate table and Coinbase spot prices with TTLs,
/// so repeated conversions in one aggregation pass do not refetch.
private actor RateCache {
  private var ecb: (table: [CurrencyCode: Decimal], asOf: Date)?
  private var spots: [String: (amount: Decimal, asOf: Date)] = [:]

  /// The cached ECB table if still within `ttl` of `freshAsOf`, else `nil`.
  func ecbTable(freshAsOf: Date, ttl: TimeInterval) -> [CurrencyCode: Decimal]? {
    guard let ecb, freshAsOf.timeIntervalSince(ecb.asOf) < ttl else { return nil }
    return ecb.table
  }

  /// Stores the ECB table with its fetch time.
  func storeECBTable(_ table: [CurrencyCode: Decimal], asOf: Date) {
    ecb = (table, asOf)
  }

  /// The cached spot for `pair` if still within `ttl` of `freshAsOf`, else `nil`.
  func spot(pair: String, freshAsOf: Date, ttl: TimeInterval) -> Decimal? {
    guard let entry = spots[pair], freshAsOf.timeIntervalSince(entry.asOf) < ttl else {
      return nil
    }
    return entry.amount
  }

  /// Stores a spot price for `pair` with its fetch time.
  func storeSpot(_ amount: Decimal, pair: String, asOf: Date) {
    spots[pair] = (amount, asOf)
  }
}
