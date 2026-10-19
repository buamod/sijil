import CommonCrypto
import CryptoKit
import Foundation

/// The built-in transform library.
///
/// PastePal ships 75+ of these; the catalogue covers the same ground using
/// Foundation's own string transforms plus small pure-Swift helpers, so there
/// is no dependency and every transform is testable in isolation.
public enum TransformCatalog {
  public static let all: [Transform] =
    caseTransforms + textTransforms
    + encodeTransforms + escapeTransforms + webTransforms
    + numberTransforms + lineTransforms + sortTransforms
    + formatTransforms + pathTransforms

  private static let byCategory: [Transform.Category: [Transform]] = {
    Dictionary(grouping: all, by: \.category)
  }()

  public static func transforms(in category: Transform.Category) -> [Transform] {
    byCategory[category] ?? []
  }

  public static func named(_ id: String) -> Transform? {
    all.first { $0.id == id }
  }

  // MARK: - Case

  private static var caseTransforms: [Transform] {
    SystemTransform.caseConversions.map { conversion in
      Transform(
        id: "case.\(conversion.name)",
        name: conversion.name,
        category: .caseConvert,
        detail: "System case conversion",
        apply: { input in
          let output = conversion.run(input)
          return output == input ? nil : output
        }
      )
    } + [
      Transform(
        id: "case.camel",
        name: "camelCase",
        category: .caseConvert,
        detail: "createTable",
        apply: { .some($0.toIdentifierCase(.camelCase)) }
      ),
      Transform(
        id: "case.pascal",
        name: "PascalCase",
        category: .caseConvert,
        detail: "CreateTable",
        apply: { .some($0.toIdentifierCase(.pascalCase)) }
      ),
      Transform(
        id: "case.snake",
        name: "snake_case",
        category: .caseConvert,
        detail: "create_table",
        apply: { .some($0.toIdentifierCase(.snakeCase)) }
      ),
      Transform(
        id: "case.kebab",
        name: "kebab-case",
        category: .caseConvert,
        detail: "create-table",
        apply: { .some($0.toIdentifierCase(.kebabCase)) }
      ),
      Transform(
        id: "case.constant",
        name: "CONSTANT_CASE",
        category: .caseConvert,
        detail: "CREATE_TABLE",
        apply: { .some($0.toIdentifierCase(.constantCase)) }
      ),
      Transform(
        id: "case.dot",
        name: "dot.case",
        category: .caseConvert,
        detail: "create.table",
        apply: { .some($0.toIdentifierCase(.dotCase)) }
      ),
      Transform(
        id: "case.path",
        name: "path/case",
        category: .caseConvert,
        detail: "create/table",
        apply: { .some($0.toIdentifierCase(.pathCase)) }
      ),
      Transform(
        id: "case.invert",
        name: "INVERT CASE",
        category: .caseConvert,
        detail: "Inverts letter case",
        apply: { input in
          let flipped = SystemTransform.togglingCase(input)
          return flipped == input ? nil : flipped
        }
      ),
    ]
  }

  // MARK: - Text

  private static var textTransforms: [Transform] {
    [
      Transform(
        id: "text.trim",
        name: "Trim",
        category: .text,
        detail: "Remove leading and trailing whitespace",
        apply: { input in
          let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
          return trimmed.isEmpty ? nil : trimmed
        }
      ),
      Transform(
        id: "text.trim-leading",
        name: "Trim leading whitespace",
        category: .text,
        detail: "De-indent each line",
        apply: { input in
          let lines = input.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
              var out = String(line)
              while out.hasPrefix(" ") || out.hasPrefix("\t") { out.removeFirst() }
              return out
            }
          let joined = lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
          return joined.isEmpty ? nil : joined
        }
      ),
      Transform(
        id: "text.squeeze-spaces",
        name: "Squeeze spaces",
        category: .text,
        detail: "Collapse runs of whitespace to one space",
        apply: { input in
          let collapsed =
            input
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
          return collapsed.isEmpty ? nil : collapsed
        }
      ),
      Transform(
        id: "text.collapse-blank-lines",
        name: "Collapse blank lines",
        category: .text,
        detail: "Reduce runs of blank lines to one",
        apply: { input in
          let lines = input.split(separator: "\n", omittingEmptySubsequences: false)
          var out: [String] = []
          var previousWasBlank = false
          for line in lines {
            let isBlank = line.trimmingCharacters(in: .whitespaces).isEmpty
            if isBlank, previousWasBlank { continue }
            out.append(String(line))
            previousWasBlank = isBlank
          }
          return out.joined(separator: "\n")
        }
      ),
      Transform(
        id: "text.tabs-to-spaces",
        name: "Tabs to spaces",
        category: .text,
        detail: "Replace tab characters with four spaces",
        apply: { $0.replacingOccurrences(of: "\t", with: "    ") }
      ),
      Transform(
        id: "text.spaces-to-tabs",
        name: "Spaces to tabs",
        category: .text,
        detail: "Replace four spaces with a tab",
        apply: { $0.replacingOccurrences(of: "    ", with: "\t") }
      ),
      Transform(
        id: "text.remove-blanks",
        name: "Remove blank lines",
        category: .text,
        detail: "Delete every empty line",
        apply: { input in
          let kept = input.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
          return kept.isEmpty ? nil : kept.joined(separator: "\n")
        }
      ),
      Transform(
        id: "text.unique-lines",
        name: "Remove duplicate lines",
        category: .text,
        detail: "Keep only the first occurrence of each line",
        apply: { input in
          var seen = Set<String>()
          let kept = input.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { seen.insert(String($0)).inserted }
          return kept.joined(separator: "\n")
        }
      ),
      Transform(
        id: "text.escape-quotes",
        name: "Escape quotes",
        category: .text,
        detail: "Backslash-escape double quotes",
        apply: { $0.replacingOccurrences(of: "\"", with: "\\\"") }
      ),
      Transform(
        id: "text.no-quotes",
        name: "Strip surrounding quotes",
        category: .text,
        detail: "Remove wrapping quotes",
        apply: { input in
          var out = input.trimmingCharacters(in: .whitespacesAndNewlines)
          if out.count >= 2,
            (out.hasPrefix("\"") && out.hasSuffix("\""))
              || (out.hasPrefix("'") && out.hasSuffix("'"))
          {
            out = String(out.dropFirst().dropLast())
          }
          return out
        }
      ),
    ]
      + SystemTransform.transliterations.map { transliteration in
        Transform(
          id: "text.\(transliteration.id)",
          name: transliteration.name,
          category: .text,
          detail: transliteration.detail,
          apply: { SystemTransform.applyTransform(transliteration.id, to: $0) }
        )
      }
  }

  // MARK: - Encode

  private static var encodeTransforms: [Transform] {
    [
      Transform(
        id: "encode.base64",
        name: "Base64 encode",
        category: .encode,
        detail: "Standard Base64",
        apply: { $0.data(using: .utf8)?.base64EncodedString() }
      ),
      Transform(
        id: "encode.base64url",
        name: "Base64 URL encode",
        category: .encode,
        detail: "URL-safe Base64 without padding",
        apply: { input in
          input.data(using: .utf8)?
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        }
      ),
      Transform(
        id: "encode.base64url-pad",
        name: "Base64 URL encode (padded)",
        category: .encode,
        detail: "URL-safe Base64 with padding",
        apply: { input in
          input.data(using: .utf8)?
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        }
      ),
      Transform(
        id: "encode.hex",
        name: "Hex encode",
        category: .encode,
        detail: "Lowercase hexadecimal bytes",
        apply: { input in
          input.data(using: .utf8)?.map { String(format: "%02x", $0) }.joined()
        }
      ),
      Transform(
        id: "encode.html-escape",
        name: "HTML escape",
        category: .encode,
        detail: "Escape &, <, >, and quotes",
        apply: { input in
          var out =
            input
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
          out = out.replacingOccurrences(of: "'", with: "&#39;")
          return out
        }
      ),
      Transform(
        id: "encode.uri",
        name: "Percent encode",
        category: .encode,
        detail: "Percent-encode for a URL",
        apply: { input in
          input.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? input
        }
      ),
    ]
  }

  // MARK: - Escape

  private static var escapeTransforms: [Transform] {
    [
      Transform(
        id: "escape.json",
        name: "Escape JSON string",
        category: .escape,
        detail: "Quote and escape as a JSON string literal",
        apply: { input in
          // Wrap in a one-element array so Foundation emits a correctly escaped
          // JSON string, then discard the array and its quotes.
          guard
            let data = try? JSONSerialization.data(withJSONObject: [input]),
            let text = String(data: data, encoding: .utf8),
            let closing = text.lastIndex(of: "]"),
            text.hasPrefix("[\"")
          else { return nil }
          var inner = String(text[text.index(text.startIndex, offsetBy: 2)..<closing])
          if inner.hasSuffix("\"") { inner.removeLast() }
          return inner
        }
      ),
      Transform(
        id: "escape.python",
        name: "Python string literal",
        category: .escape,
        detail: "Wrap in single quotes, escaping as Python needs",
        apply: { input in
          let escaped =
            input
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
          return "'\(escaped)'"
        }
      ),
      Transform(
        id: "escape.shell",
        name: "Shell single-quote",
        category: .escape,
        detail: "Quote safely for a POSIX shell",
        apply: { input in
          // Single quotes protect everything except a single quote itself, which
          // must close-quote-escape-reopen.
          "'" + input.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
      ),
      Transform(
        id: "escape.sql",
        name: "SQL single-quote",
        category: .escape,
        detail: "Double single quotes for SQL",
        apply: { input in input.replacingOccurrences(of: "'", with: "''") }
      ),
      Transform(
        id: "escape.regex",
        name: "Escape regex",
        category: .escape,
        detail: "Backslash every regex metacharacter",
        apply: { input in
          let metacharacters = #"\.+*?()|[]{}^$"#
          var out = ""
          for character in input {
            if metacharacters.contains(character) {
              out.append("\\")
            }
            out.append(character)
          }
          return out
        }
      ),
    ]
  }

  // MARK: - Web

  private static var webTransforms: [Transform] {
    [
      Transform(
        id: "web.url-decode",
        name: "URL decode",
        category: .web,
        detail: "Percent-decode",
        apply: { $0.removingPercentEncoding }
      ),
      Transform(
        id: "web.query",
        name: "URL query parameters",
        category: .web,
        detail: "One parameter per line",
        apply: { input in
          guard let components = URLComponents(string: input),
            let items = components.queryItems, !items.isEmpty
          else { return nil }
          let maxKey = items.map { $0.name.count }.max() ?? 0
          return
            items
            .map { item -> String in
              let name = item.name.padding(
                toLength: max(maxKey, item.name.count),
                withPad: " ",
                startingAt: 0
              )
              return "\(name) = \(item.value ?? "")"
            }
            .joined(separator: "\n")
        }
      ),
      Transform(
        id: "web.json-pretty",
        name: "Pretty-print JSON",
        category: .web,
        detail: "Reformat JSON with two-space indentation",
        apply: { input in
          guard
            let data = input.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            JSONSerialization.isValidJSONObject(object),
            let pretty = try? JSONSerialization.data(
              withJSONObject: object,
              options: [.prettyPrinted, .sortedKeys]
            )
          else { return nil }
          return String(data: pretty, encoding: .utf8)
        }
      ),
      Transform(
        id: "web.json-minify",
        name: "Minify JSON",
        category: .web,
        detail: "Strip JSON whitespace",
        apply: { input in
          guard
            let data = input.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let minified = try? JSONSerialization.data(withJSONObject: object)
          else { return nil }
          return String(data: minified, encoding: .utf8)
        }
      ),
      Transform(
        id: "web.strip-tags",
        name: "Strip HTML tags",
        category: .web,
        detail: "Remove tags, leaving text",
        apply: { input in
          let pattern = #"<[^>]+>"#
          guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
          let range = NSRange(input.startIndex..., in: input)
          let stripped = regex.stringByReplacingMatches(in: input, range: range, withTemplate: " ")
          let collapsed =
            stripped
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
          return collapsed.isEmpty ? nil : collapsed
        }
      ),
      Transform(
        id: "web.slug",
        name: "URL slug",
        category: .web,
        detail: "Lowercase with hyphens",
        apply: { input in
          // ASCII-fold first, so "Café Über" slugs to "cafe-uber" rather than keeping
          // the accent, then strip what remains.
          let transliterated =
            SystemTransform.applyTransform(
              "Any-Latin; Latin-ASCII",
              to: input
            ) ?? input
          let lowered = transliterated.lowercased()
          var slug = ""
          var previousWasHyphen = false
          for character in lowered {
            if character.isLetter || character.isNumber {
              slug.append(character)
              previousWasHyphen = false
            } else if !previousWasHyphen, !slug.isEmpty {
              slug.append("-")
              previousWasHyphen = true
            }
          }
          return slug.isEmpty ? nil : slug
        }
      ),
      Transform(
        id: "web.markdown-link",
        name: "Markdown link",
        category: .web,
        detail: "[text](url) from URL and title",
        apply: { input in
          guard
            let url = URL(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
            let scheme = url.scheme, ["http", "https", "mailto"].contains(scheme)
          else { return nil }
          let text =
            url.absoluteString == input
            ? (url.host ?? url.absoluteString)
            : input
          return "[\(text)](\(url.absoluteString))"
        }
      ),
    ]
  }

  // MARK: - Number

  private static var numberTransforms: [Transform] {
    [
      Transform(
        id: "number.sha256",
        name: "SHA-256",
        category: .number,
        detail: "Hex digest of the UTF-8 bytes",
        apply: { input in
          SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
        }
      ),
      Transform(
        id: "number.md5",
        name: "MD5",
        category: .number,
        detail: "Hex digest (fingerprint only, not for security)",
        apply: { input in
          MD5Digest.hex(of: input)
        }
      ),
      Transform(
        id: "number.crc32",
        name: "CRC-32",
        category: .number,
        detail: "Checksum as decimal",
        apply: { input in
          var crc: UInt32 = 0xFFFF_FFFF
          for byte in Data(input.utf8) {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
              crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1)))
            }
          }
          return String(crc ^ 0xFFFF_FFFF)
        }
      ),
      Transform(
        id: "number.bytes",
        name: "Byte count",
        category: .number,
        detail: "UTF-8 length in bytes",
        apply: { String(Data($0.utf8).count) }
      ),
      Transform(
        id: "number.chars",
        name: "Character count",
        category: .number,
        detail: "Grapheme count",
        apply: { String($0.count) }
      ),
      Transform(
        id: "number.lines",
        name: "Line count",
        category: .number,
        detail: "Number of lines",
        apply: { String($0.split(separator: "\n", omittingEmptySubsequences: false).count) }
      ),
      Transform(
        id: "number.words",
        name: "Word count",
        category: .number,
        detail: "Whitespace-separated words",
        apply: { String($0.split(whereSeparator: \.isWhitespace).count) }
      ),
      Transform(
        id: "number.sum",
        name: "Sum numbers",
        category: .number,
        detail: "Add every number found",
        apply: { input in
          let pattern = #"-?\d+(?:\.\d+)?"#
          guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
          let range = NSRange(input.startIndex..., in: input)
          let values = regex.matches(in: input, range: range).compactMap { match -> Double? in
            guard let swiftRange = Range(match.range, in: input) else { return nil }
            return Double(input[swiftRange])
          }
          guard !values.isEmpty else { return nil }
          let total = values.reduce(0, +)
          return total == total.rounded() ? String(Int(total)) : String(total)
        }
      ),
      Transform(
        id: "number.roman",
        name: "To Roman numeral",
        category: .number,
        detail: "Integer to Roman numerals",
        apply: { input in
          guard
            let value = Int(input.trimmingCharacters(in: .whitespacesAndNewlines)),
            (1...3999).contains(value)
          else { return nil }
          return Self.roman(value)
        }
      ),
      Transform(
        id: "number.epoch-to-date",
        name: "Epoch to date",
        category: .number,
        detail: "Unix timestamp to ISO 8601",
        apply: { input in
          guard let seconds = TimeInterval(input.trimmingCharacters(in: .whitespacesAndNewlines))
          else { return nil }
          return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: seconds))
        }
      ),
      Transform(
        id: "number.date-to-epoch",
        name: "Date to epoch",
        category: .number,
        detail: "ISO 8601 to Unix timestamp",
        apply: { input in
          let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
          guard
            let date = ISO8601DateFormatter().date(from: trimmed)
              ?? DateFormatter.iso8601Flexible.date(from: trimmed)
          else { return nil }
          return String(Int(date.timeIntervalSince1970))
        }
      ),
      Transform(
        id: "number.base-convert",
        name: "Decimal to hex",
        category: .number,
        detail: "Integer in decimal to hexadecimal",
        apply: { input in
          let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
          guard let value = UInt64(trimmed) else { return nil }
          return String(value, radix: 16, uppercase: true)
        }
      ),
    ]
  }

  private static func roman(_ value: Int) -> String {
    let table: [(Int, String)] = [
      (1000, "M"), (900, "CM"), (500, "D"), (400, "CD"),
      (100, "C"), (90, "XC"), (50, "L"), (40, "XL"),
      (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I"),
    ]
    var remaining = value
    var out = ""
    for (number, numeral) in table {
      while remaining >= number {
        out += numeral
        remaining -= number
      }
    }
    return out
  }

  // MARK: - Lines

  private static var lineTransforms: [Transform] {
    [
      Transform(
        id: "lines.reverse",
        name: "Reverse lines",
        category: .lines,
        detail: "Last line first",
        apply: { input in
          let lines = input.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .reversed()
          return lines.joined(separator: "\n")
        }
      ),
      Transform(
        id: "lines.sort-alpha",
        name: "Sort lines A→Z",
        category: .lines,
        detail: "Alphabetical",
        apply: { input in
          Self.sortLines(input) { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }
      ),
      Transform(
        id: "lines.sort-length",
        name: "Sort lines by length",
        category: .lines,
        detail: "Shortest first",
        apply: { input in Self.sortLines(input) { $0.count < $1.count } }
      ),
      Transform(
        id: "lines.numbers-strip",
        name: "Remove line numbers",
        category: .lines,
        detail: "Strip a leading '12. ' or '12: '",
        apply: { input in
          // Anchored per line via `(?m)`, so a number mid-line is left alone.
          let pattern = #"(?m)^\s*\d+[.):]\s?"#
          guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
          let range = NSRange(input.startIndex..., in: input)
          return regex.stringByReplacingMatches(in: input, range: range, withTemplate: "")
        }
      ),
      Transform(
        id: "lines.prefix",
        name: "Add line prefix",
        category: .lines,
        detail: "Prefix each line with '# '",
        apply: { input in
          input.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "# \($0)" }
            .joined(separator: "\n")
        }
      ),
      Transform(
        id: "lines.unindent",
        name: "Remove common indentation",
        category: .lines,
        detail: "Strip the shared leading whitespace",
        apply: { input in
          let lines = input.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
          let indents = lines.compactMap { line -> Int? in
            let prefix = line.prefix { $0 == " " || $0 == "\t" }
            return prefix.isEmpty ? nil : prefix.count
          }
          guard let minimum = indents.min(), minimum > 0 else { return input }
          return
            lines
            .map { line -> String in
              line.count >= minimum ? String(line.dropFirst(minimum)) : line
            }
            .joined(separator: "\n")
        }
      ),
    ]
  }

  private static func sortLines(
    _ input: String,
    by areInOrder: (String, String) -> Bool
  ) -> String? {
    var lines = input.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    // Swift's sort is not stable, so tie-break on the original order.
    let indexed = lines.enumerated().sorted { lhs, rhs in
      if areInOrder(lhs.element, rhs.element) { return true }
      if areInOrder(rhs.element, lhs.element) { return false }
      return lhs.offset < rhs.offset
    }
    lines = indexed.map(\.element)
    let joined = lines.joined(separator: "\n")
    return joined.isEmpty ? nil : joined
  }

  // MARK: - Sort

  /// Splits on newlines, dropping a trailing empty segment from the final line
  /// break so sorting does not move an empty row to the top.
  private static func lines(of input: String) -> [String] {
    var result = input.split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
    if result.count > 1, result.last?.isEmpty == true {
      result.removeLast()
    }
    return result
  }

  private static func joinedLines(_ lines: [String]) -> String {
    lines.joined(separator: "\n")
  }

  /// Case-insensitive alphabetical, with a stable tie-break.
  private static func sortedByName(_ lines: [String]) -> [String] {
    lines.enumerated()
      .sorted { lhs, rhs in
        let order = lhs.element.localizedCaseInsensitiveCompare(rhs.element)
        if order != .orderedSame { return order == .orderedAscending }
        return lhs.offset < rhs.offset
      }
      .map(\.element)
  }

  private static var sortTransforms: [Transform] {
    [
      Transform(
        id: "sort.alpha",
        name: "Sort A→Z",
        category: .sort,
        detail: "Alphabetical",
        apply: { input in joinedLines(sortedByName(lines(of: input))) }
      ),
      Transform(
        id: "sort.reverse-alpha",
        name: "Sort Z→A",
        category: .sort,
        detail: "Reverse alphabetical",
        apply: { input in joinedLines(sortedByName(lines(of: input)).reversed()) }
      ),
      Transform(
        id: "sort.numeric",
        name: "Sort numerically",
        category: .sort,
        detail: "By parsed number",
        apply: { input in
          let sorted = lines(of: input).enumerated().sorted { lhs, rhs in
            let left = Double(lhs.element.trimmingCharacters(in: .whitespaces)) ?? 0
            let right = Double(rhs.element.trimmingCharacters(in: .whitespaces)) ?? 0
            if left == right { return lhs.offset < rhs.offset }
            return left < right
          }
          return joinedLines(sorted.map(\.element))
        }
      ),
      Transform(
        id: "sort.length",
        name: "Sort by length",
        category: .sort,
        detail: "Shortest first",
        // Equal lengths fall back to alphabetical so the result is
        // deterministic rather than dependent on enumeration order.
        apply: { input in
          let sorted = lines(of: input).enumerated().sorted { lhs, rhs in
            if lhs.element.count != rhs.element.count {
              return lhs.element.count < rhs.element.count
            }
            let order = lhs.element.localizedCaseInsensitiveCompare(rhs.element)
            return order == .orderedSame ? lhs.offset < rhs.offset : order == .orderedAscending
          }
          return joinedLines(sorted.map(\.element))
        }
      ),
      Transform(
        id: "sort.random",
        name: "Shuffle",
        category: .sort,
        detail: "Randomise line order",
        apply: { input in joinedLines(lines(of: input).shuffled()) }
      ),
      Transform(
        id: "sort.unique",
        name: "Remove duplicates",
        category: .sort,
        detail: "Unique lines, first occurrence kept",
        apply: { input in
          var seen = Set<String>()
          let kept = lines(of: input).filter { seen.insert($0).inserted }
          return joinedLines(kept)
        }
      ),
    ]
  }

  // MARK: - Format

  private static var formatTransforms: [Transform] {
    [
      Transform(
        id: "format.markdown-table",
        name: "Markdown table",
        category: .format,
        detail: "Treat whitespace-aligned columns as a table",
        apply: { input in
          let lines = input.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
          guard lines.count >= 2 else { return nil }
          let header = lines[0].split(separator: "\t", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
          guard header.count > 1 else { return nil }
          let divider = "| " + header.map { _ in "---" }.joined(separator: " | ") + " |"
          let body = lines.dropFirst().map { line -> String in
            let cells = line.split(separator: "\t", omittingEmptySubsequences: false)
              .map { $0.trimmingCharacters(in: .whitespaces) }
            return "| " + cells.joined(separator: " | ") + " |"
          }
          let top = "| " + header.joined(separator: " | ") + " |"
          return ([top, divider] + body).joined(separator: "\n")
        }
      ),
      Transform(
        id: "format.csv-to-tsv",
        name: "CSV to TSV",
        category: .format,
        detail: "Comma-separated to tab-separated",
        apply: { input in Self.delimited(input, from: ",", to: "\t") }
      ),
      Transform(
        id: "format.tsv-to-csv",
        name: "TSV to CSV",
        category: .format,
        detail: "Tab-separated to comma-separated",
        apply: { input in Self.delimited(input, from: "\t", to: ",") }
      ),
      Transform(
        id: "format.csv-to-json",
        name: "CSV to JSON",
        category: .format,
        detail: "Header row becomes object keys",
        apply: { input in
          let rows = Self.parseCSV(input)
          guard let header = rows.first, header.count > 1, rows.count > 1 else { return nil }
          let objects: [[String: String]] = rows.dropFirst().compactMap { row in
            guard row.count == header.count else { return nil }
            return Dictionary(uniqueKeysWithValues: zip(header, row))
          }
          guard
            let data = try? JSONSerialization.data(
              withJSONObject: objects,
              options: [.prettyPrinted, .sortedKeys]
            )
          else { return nil }
          return String(data: data, encoding: .utf8)
        }
      ),
      Transform(
        id: "format.json-to-csv",
        name: "JSON to CSV",
        category: .format,
        detail: "Array of objects to comma-separated",
        apply: { input in
          guard
            let data = input.data(using: .utf8),
            let parsed = try? JSONSerialization.jsonObject(with: data),
            let array = parsed as? [[String: Any]],
            !array.isEmpty
          else { return nil }
          let keys = array.flatMap { $0.keys }.sorted()
          var lines = [keys.joined(separator: ",")]
          for object in array {
            lines.append(
              keys
                .map { key -> String in
                  Self.csvField(object[key].map(String.init(describing:)) ?? "")
                }
                .joined(separator: ",")
            )
          }
          return lines.joined(separator: "\n")
        }
      ),
      Transform(
        id: "format.wrap",
        name: "Hard wrap",
        category: .format,
        detail: "Wrap at 80 columns on word boundaries",
        apply: { input in input.wordWrapped(to: 80) }
      ),
    ]
  }

  private static func csvField(_ value: String) -> String {
    if value.contains(",") || value.contains("\"") || value.contains("\n") {
      return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    return value
  }

  /// Minimal RFC 4180 reader: handles quoted fields, escaped quotes, and
  /// newlines inside quotes.
  static func parseCSV(_ input: String) -> [[String]] {
    var rows: [[String]] = []
    var row: [String] = []
    var field = ""
    var insideQuotes = false
    var iterator = input.makeIterator()
    var pending: Character?

    func commitField() {
      row.append(field)
      field = ""
    }
    func commitRow() {
      commitField()
      rows.append(row)
      row = []
    }

    while let character = pending ?? iterator.next() {
      pending = nil
      if insideQuotes {
        if character == "\"" {
          if let next = iterator.next() {
            if next == "\"" {
              field.append("\"")
            } else {
              insideQuotes = false
              pending = next
            }
          } else {
            insideQuotes = false
          }
        } else {
          field.append(character)
        }
        continue
      }
      switch character {
      case "\"": insideQuotes = true
      case ",": commitField()
      case "\n": commitRow()
      case "\r": break
      default: field.append(character)
      }
    }
    if !field.isEmpty || !row.isEmpty { commitRow() }
    return rows.filter { $0.contains { !$0.isEmpty } }
  }

  private static func delimited(
    _ input: String, from separator: Character, to output: Character
  ) -> String? {
    let rows =
      separator == "," ? parseCSV(input) : parseCSV(input.replacingOccurrences(of: "\t", with: ","))
    guard !rows.isEmpty else { return nil }
    return
      rows
      .map { row in
        row.map { field -> String in
          field.contains(output) ? "\"\(field)\"" : field
        }.joined(separator: String(output))
      }
      .joined(separator: "\n")
  }

  // MARK: - Path

  private static var pathTransforms: [Transform] {
    [
      Transform(
        id: "path.basename",
        name: "Basename",
        category: .path,
        detail: "Last path component",
        apply: { input in URL(fileURLWithPath: input).lastPathComponent.nilIfEmpty }
      ),
      Transform(
        id: "path.dirname",
        name: "Directory",
        category: .path,
        detail: "Parent directory",
        apply: { input in
          let url = URL(fileURLWithPath: input).deletingLastPathComponent()
          return url.path == "/" ? nil : url.path
        }
      ),
      Transform(
        id: "path.extension",
        name: "Extension",
        category: .path,
        detail: "File extension without the dot",
        apply: { input in URL(fileURLWithPath: input).pathExtension.nilIfEmpty }
      ),
      Transform(
        id: "path.stem",
        name: "Filename stem",
        category: .path,
        detail: "Basename without extension",
        apply: { input in
          let url = URL(fileURLWithPath: input)
          let stem = url.deletingPathExtension().lastPathComponent
          return stem == "/" ? nil : stem
        }
      ),
      Transform(
        id: "path.tilde",
        name: "Home to ~",
        category: .path,
        detail: "Shorten the home directory",
        apply: { input in
          let home = FileManager.default.homeDirectoryForCurrentUser.path
          return input.hasPrefix(home) ? "~" + input.dropFirst(home.count) : input
        }
      ),
      Transform(
        id: "path.untilde",
        name: "~ to home",
        category: .path,
        detail: "Expand a leading tilde",
        apply: { input in
          guard input.hasPrefix("~") else { return nil }
          let home = FileManager.default.homeDirectoryForCurrentUser.path
          return home + input.dropFirst()
        }
      ),
    ]
  }
}

// MARK: - Identifier casing

extension String {
  enum IdentifierCase {
    case camelCase, pascalCase, snakeCase, constantCase, kebabCase, dotCase, pathCase
  }

  /// Splits on non-alphanumerics and on lower→upper transitions, then rejoins
  /// in the requested style.
  func toIdentifierCase(_ style: IdentifierCase) -> String {
    var words: [String] = []
    var current = ""

    /// Break before an uppercase letter when the run so far is not entirely
    /// uppercase — that splits "createTable" into ["create", "Table"] while
    /// leaving "HTTPServer" whole instead of shattering it into single letters.
    /// Break before an uppercase letter when the preceding character was
    /// lowercase or a digit — that splits "createTable" into ["create",
    /// "Table"] while leaving "HTTPServer" whole instead of shattering it
    /// into single letters.
    func shouldBreakBeforeUppercase(_ previous: Character?) -> Bool {
      guard let previous else { return false }
      return !previous.isUppercase
    }

    var previous: Character?
    for character in self {
      if !character.isLetter && !character.isNumber {
        if !current.isEmpty { words.append(current) }
        current = ""
        previous = nil
        continue
      }
      if character.isUppercase, shouldBreakBeforeUppercase(previous) {
        words.append(current)
        current = ""
      }
      current.append(character)
      previous = character
    }
    if !current.isEmpty { words.append(current) }

    guard !words.isEmpty else { return self }

    switch style {
    case .camelCase:
      let head = words.first!.lowercased()
      return head + words.dropFirst().map(\.capitalizedFirst).joined()
    case .pascalCase:
      return words.map(\.capitalizedFirst).joined()
    case .snakeCase:
      return words.map { $0.lowercased() }.joined(separator: "_")
    case .constantCase:
      return words.map { $0.uppercased() }.joined(separator: "_")
    case .kebabCase:
      return words.map { $0.lowercased() }.joined(separator: "-")
    case .dotCase:
      return words.map { $0.lowercased() }.joined(separator: ".")
    case .pathCase:
      return words.map { $0.lowercased() }.joined(separator: "/")
    }
  }

  fileprivate var capitalizedFirst: String {
    guard let first else { return self }
    return first.uppercased() + dropFirst()
  }

  fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension String {
  /// Wraps on word boundaries, breaking over-long words so a URL cannot blow out
  /// the column limit.
  func wordWrapped(to width: Int, indent: String = "") -> String {
    guard width > 0 else { return self }
    var out: [String] = []
    for paragraph in split(separator: "\n", omittingEmptySubsequences: false) {
      if paragraph.isEmpty {
        out.append(indent)
        continue
      }
      var line = indent
      for word in paragraph.split(separator: " ", omittingEmptySubsequences: false) {
        if line == indent {
          line += word
        } else if line.count + 1 + word.count <= width {
          line += " " + word
        } else {
          out.append(line)
          line = indent + word
        }
        // A single word longer than the limit must still be broken.
        while line.count > width {
          let breakAt = width
          out.append(String(line[line.startIndex..<line.index(line.startIndex, offsetBy: breakAt)]))
          line = indent + String(line[line.index(line.startIndex, offsetBy: breakAt)...])
        }
      }
      out.append(line)
    }
    return out.joined(separator: "\n")
  }
}

extension DateFormatter {
  /// Accepts the date shapes people actually paste, not just strict ISO 8601.
  static let iso8601Flexible: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter
  }()
}
