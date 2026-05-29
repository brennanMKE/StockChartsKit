import Foundation

/// A minimal, dependency-free CSV tokenizer.
///
/// Handles the common dialect used by brokerage exports: comma-separated
/// fields, optional double-quoted fields (with `""` as an escaped quote),
/// surrounding whitespace, and blank lines. It is deliberately small — it does
/// not attempt to support exotic delimiters or multi-line quoted fields that
/// span physical newlines, which brokerage position/balance exports do not use.
enum CSVParsing {
  /// Splits raw CSV text into rows of trimmed string fields.
  ///
  /// Blank lines (after trimming) are skipped entirely. Quoted fields preserve
  /// their interior whitespace and may contain commas; unquoted fields are
  /// trimmed of surrounding whitespace.
  ///
  /// - Parameter text: The full CSV document.
  /// - Returns: One `[String]` per non-empty line, in document order.
  static func rows(from text: String) -> [[String]] {
    var rows: [[String]] = []
    // Normalise line endings, then split on newlines. Brokerage exports do not
    // embed raw newlines inside quoted fields, so a line-based split is safe.
    let normalized = text
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
    for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
      let fields = self.fields(in: String(line))
      // Skip lines that are entirely empty or whitespace.
      if fields.allSatisfy({ $0.isEmpty }) { continue }
      rows.append(fields)
    }
    return rows
  }

  /// Tokenizes a single physical line into fields.
  private static func fields(in line: String) -> [String] {
    var fields: [String] = []
    var current = ""
    var inQuotes = false
    var iterator = line.makeIterator()
    var pending: Character? = nil

    func nextChar() -> Character? {
      if let p = pending {
        pending = nil
        return p
      }
      return iterator.next()
    }

    while let char = nextChar() {
      if inQuotes {
        if char == "\"" {
          // A doubled quote inside a quoted field is a literal quote.
          if let peek = iterator.next() {
            if peek == "\"" {
              current.append("\"")
            } else {
              inQuotes = false
              pending = peek
            }
          } else {
            inQuotes = false
          }
        } else {
          current.append(char)
        }
      } else {
        switch char {
        case "\"":
          inQuotes = true
        case ",":
          fields.append(self.normalize(current, wasQuoted: false))
          current = ""
        default:
          current.append(char)
        }
      }
    }
    fields.append(self.normalize(current, wasQuoted: false))
    return fields
  }

  /// Trims surrounding whitespace from an unquoted field.
  private static func normalize(_ field: String, wasQuoted: Bool) -> String {
    wasQuoted ? field : field.trimmingCharacters(in: .whitespaces)
  }
}
