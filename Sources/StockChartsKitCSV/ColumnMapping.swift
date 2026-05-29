import Foundation

/// Describes how the columns of a CSV file map onto the fields the
/// ``CSVImportProvider`` needs.
///
/// A mapping resolves each logical field (``Field``) to a physical column. Two
/// resolution strategies are supported:
///
/// - **Positional** (``positional(_:)``): the field is at a fixed zero-based
///   column index. Use this for headerless files such as `AMD,12,490.70`.
/// - **Header-based** (``header(_:)``): the field is in the column whose header
///   text (case-insensitively, trimmed) matches a given name. Use this for
///   files that begin with a header row.
///
/// A single ``ColumnMapping`` mixes the two freely; for example a header-based
/// positions file might still pin one column positionally.
public struct ColumnMapping: Sendable, Hashable {
  /// A logical field the provider can extract from a CSV row.
  public enum Field: String, Sendable, Hashable, CaseIterable {
    /// The account identifier the row belongs to.
    case account
    /// The ticker symbol (positions only).
    case symbol
    /// The quantity held (positions only).
    case quantity
    /// The per-unit price (positions only); used to derive market value when
    /// ``marketValue`` is absent.
    case price
    /// The total market value of the holding (positions only).
    case marketValue
    /// The average cost per unit (positions only, optional).
    case averageCost
    /// The asset class (positions only, optional; defaults to `.equity`).
    case assetClass
    /// The total account value (balances only).
    case total
    /// The settled cash balance (balances only).
    case cash
    /// Buying power (balances only, optional).
    case buyingPower
  }

  /// How a single field locates its column.
  public enum Column: Sendable, Hashable {
    /// The field is at a fixed zero-based column index (headerless files).
    case positional(Int)
    /// The field is in the column whose header matches this name
    /// (case-insensitively, trimmed).
    case header(String)
  }

  /// Whether the first data row is a header row to be skipped.
  ///
  /// This is independent of resolution strategy: a positional mapping may still
  /// declare a header row that should be ignored when parsing data.
  public let hasHeaderRow: Bool

  /// The per-field column resolutions.
  public let columns: [Field: Column]

  /// Creates a column mapping.
  ///
  /// - Parameters:
  ///   - hasHeaderRow: Whether the first row is a header to skip. Defaults to
  ///     `true` when any column is header-based, otherwise `false`.
  ///   - columns: The per-field column resolutions.
  public init(hasHeaderRow: Bool? = nil, columns: [Field: Column]) {
    let anyHeader = columns.values.contains { if case .header = $0 { true } else { false } }
    self.hasHeaderRow = hasHeaderRow ?? anyHeader
    self.columns = columns
  }

  /// The default positions mapping for the headerless `symbol,quantity,price`
  /// convention, e.g. `AMD,12,490.70`.
  ///
  /// Market value is derived as `quantity × price`. Rows have no account
  /// column, so the provider's fallback account identifier is used.
  public static let defaultPositionsPositional = ColumnMapping(
    hasHeaderRow: false,
    columns: [
      .symbol: .positional(0),
      .quantity: .positional(1),
      .price: .positional(2),
    ]
  )

  /// The default header-based positions mapping.
  ///
  /// Recognises the headers `account`, `symbol`, `quantity`, `marketValue`,
  /// `averageCost`, and `assetClass`. Only `symbol`, `quantity`, and
  /// `marketValue` are required at parse time.
  public static let defaultPositionsHeader = ColumnMapping(
    columns: [
      .account: .header("account"),
      .symbol: .header("symbol"),
      .quantity: .header("quantity"),
      .marketValue: .header("marketValue"),
      .averageCost: .header("averageCost"),
      .assetClass: .header("assetClass"),
    ]
  )

  /// The default header-based balances mapping.
  ///
  /// Recognises the headers `account`, `total`, `cash`, and `buyingPower`.
  public static let defaultBalancesHeader = ColumnMapping(
    columns: [
      .account: .header("account"),
      .total: .header("total"),
      .cash: .header("cash"),
      .buyingPower: .header("buyingPower"),
    ]
  )
}
