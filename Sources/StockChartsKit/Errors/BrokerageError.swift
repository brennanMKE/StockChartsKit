import Foundation

/// The unified error space for the package.
///
/// Every provider maps its native errors into one of these cases. Provider
/// implementations may attach extra context via ``providerError(providerID:statusCode:message:)``.
public enum BrokerageError: Error, Sendable {
  /// No valid session exists; the caller must authenticate first.
  case notAuthenticated
  /// Authentication was attempted but failed for the given reason.
  case authenticationFailed(reason: String)
  /// A previously valid authorization has been revoked by the provider or user.
  case authorizationRevoked
  /// The provider rate-limited the request; retry no earlier than `retryAfter`.
  case rateLimited(retryAfter: Date?)
  /// The named method is not supported by this provider.
  case unsupported(method: String)
  /// Arithmetic or aggregation was attempted across mismatched currencies.
  case currencyMismatch(lhs: CurrencyCode, rhs: CurrencyCode)
  /// A provider-specific error, optionally carrying an HTTP status code.
  case providerError(providerID: ProviderID, statusCode: Int?, message: String)
  /// Decoding a provider response failed.
  case decodingFailed(underlying: Error)
  /// A networking error occurred.
  case network(underlying: Error)
  /// The requested symbol could not be resolved.
  case missingSymbol(Symbol)
  /// The returned data is stale as of the given date.
  case stale(asOf: Date)
}
