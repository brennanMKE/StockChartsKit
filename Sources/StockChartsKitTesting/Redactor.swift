import Foundation

/// A helper for scrubbing secrets and PII out of recorded responses before they
/// are committed as fixtures.
///
/// Fixtures are recorded from *real* responses, which means they may contain
/// access tokens, refresh tokens, account numbers, names, and emails. **None of
/// that may ever be committed** (PRD §5.1, §12, §18). Run a recorded body
/// through ``redact(_:)`` and review it against ``checklist`` before saving.
///
/// ```swift
/// var redactor = Redactor()
/// redactor.redactKeys = ["access_token", "refresh_token", "accountNumber"]
/// let safe = redactor.redact(rawBody)
/// ```
public struct Redactor: Sendable {
  /// JSON object keys whose values are replaced with ``placeholder`` wherever
  /// they appear, at any nesting depth.
  public var redactKeys: Set<String>

  /// Literal substrings replaced with ``placeholder`` (e.g. a known token or
  /// account number captured during recording).
  public var redactValues: Set<String>

  /// The replacement string written in place of redacted content.
  public var placeholder: String

  /// Creates a redactor.
  ///
  /// - Parameters:
  ///   - redactKeys: JSON keys to scrub. Defaults to a common set of
  ///     credential/PII field names.
  ///   - redactValues: Literal substrings to scrub. Defaults to empty.
  ///   - placeholder: The replacement marker. Defaults to `"REDACTED"`.
  public init(
    redactKeys: Set<String> = Redactor.defaultKeys,
    redactValues: Set<String> = [],
    placeholder: String = "REDACTED"
  ) {
    self.redactKeys = redactKeys
    self.redactValues = redactValues
    self.placeholder = placeholder
  }

  /// A starting set of field names that commonly carry secrets or PII.
  public static let defaultKeys: Set<String> = [
    "access_token", "accessToken",
    "refresh_token", "refreshToken",
    "id_token", "idToken",
    "token", "secret", "client_secret", "clientSecret",
    "password", "apiKey", "api_key",
    "authorization", "Authorization",
    "ssn", "taxId", "tax_id",
    "accountNumber", "account_number",
    "email", "phone", "phoneNumber",
    "firstName", "lastName", "fullName", "name",
    "address", "dateOfBirth", "dob",
  ]

  /// Redacts `data` interpreted as JSON; on success returns pretty-printed,
  /// scrubbed JSON, otherwise returns the input scrubbed only for literal
  /// ``redactValues`` (so non-JSON bodies are still partly protected).
  public func redact(_ data: Data) -> Data {
    guard
      let object = try? JSONSerialization.jsonObject(
        with: data,
        options: [.fragmentsAllowed]
      )
    else {
      return redactLiterals(in: data)
    }
    let scrubbed = redactJSON(object)
    guard
      let out = try? JSONSerialization.data(
        withJSONObject: scrubbed,
        options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]
      )
    else {
      return redactLiterals(in: data)
    }
    return out
  }

  /// A human-readable checklist for reviewers, embedded so it travels with the
  /// code. Print it or paste it into a recording script.
  public static let checklist: String = """
    Fixture redaction checklist (review every recorded fixture before commit):
      [ ] No access / refresh / id tokens, API keys, or client secrets.
      [ ] No Authorization headers or cookies in stored response headers.
      [ ] No account numbers, SSNs, or tax IDs.
      [ ] No names, emails, phone numbers, or postal addresses.
      [ ] No real balances/positions if they identify a person — synthesize.
      [ ] URLs and query strings carry no embedded tokens.
      [ ] Diff the fixture before committing; never paste a live response raw.
    """

  // MARK: Internals

  private func redactJSON(_ value: Any) -> Any {
    if let dict = value as? [String: Any] {
      var out: [String: Any] = [:]
      for (key, child) in dict {
        if redactKeys.contains(key) {
          out[key] = placeholder
        } else {
          out[key] = redactJSON(child)
        }
      }
      return out
    }
    if let array = value as? [Any] {
      return array.map(redactJSON)
    }
    if let string = value as? String, redactValues.contains(string) {
      return placeholder
    }
    return value
  }

  private func redactLiterals(in data: Data) -> Data {
    guard !redactValues.isEmpty, var text = String(data: data, encoding: .utf8) else {
      return data
    }
    for value in redactValues where !value.isEmpty {
      text = text.replacingOccurrences(of: value, with: placeholder)
    }
    return Data(text.utf8)
  }
}
