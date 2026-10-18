import CoreFoundation
import Foundation

/// System-provided text conversion.
///
/// Two separate mechanisms, because neither covers everything:
///
/// - **Case conversion** uses Swift's own `String` APIs. `CFStringTransform`
///   accepts `"lowercase"` and friends as transform names but returns `false`
///   for all of them, and `StringTransform` has no such cases in Swift — so the
///   transform table is not the right tool here.
/// - **Transliteration** uses `CFStringTransform` with ICU language pairs
///   (`"Cyrillic-Latin"`, `"Any-Latin; Latin-ASCII"`), which does work and is
///   the same engine TextEdit uses.
enum SystemTransform {
  /// Case conversions, backed by `String`.
  static let caseConversions: [(name: String, run: @Sendable (String) -> String)] = [
    ("lowercase", { $0.lowercased() }),
    ("UPPERCASE", { $0.uppercased() }),
    ("Capitalized", { $0.capitalized }),
    ("Title Case", { SystemTransform.titleCase($0) }),
    ("Sentence case", { SystemTransform.sentenceCase($0) }),
    ("tOGGLE cASE", { SystemTransform.togglingCase($0) }),
  ]

  /// Transliterations, backed by ICU.
  static let transliterations: [(name: String, id: String, detail: String)] = [
    ("To Latin (keep accents)", "Any-Latin", "Café stays Café"),
    ("To ASCII", "Any-Latin; Latin-ASCII", "Café becomes Cafe"),
    ("To ASCII lowercase", "Any-Latin; Latin-ASCII; Lowercase", "Café becomes cafe"),
    ("To ASCII uppercase", "Any-Latin; Latin-ASCII; Uppercase", "CAFE"),
    ("Cyrillic to Latin", "Cyrillic-Latin", "Привет becomes Privet"),
    ("Greek to Latin", "Greek-Latin", "Γειά becomes Geiá"),
    ("Arabic to Latin", "Arabic-Latin", "مرحبا becomes mrḥbạ"),
    ("Hebrew to Latin", "Hebrew-Latin", "Latin approximation"),
    ("Japanese Kana swap", "Hiragana-Katakana", "ひらがな becomes ヒラガナ"),
    ("Fullwidth to halfwidth", "Fullwidth-Halfwidth", "ＡＢＣ becomes ABC"),
    ("Halfwidth to fullwidth", "Halfwidth-Fullwidth", "ABC becomes ＡＢＣ"),
    ("Fullwidth to ASCII", "Fullwidth-Halfwidth; Latin-ASCII", "ＡＢＣ becomes ABC"),
  ]

  /// Applies an ICU transform. Returns nil when ICU declines, which it does for
  /// input containing no characters the transform can affect.
  static func applyTransform(_ identifier: String, to input: String) -> String? {
    let mutable = CFStringCreateMutable(kCFAllocatorDefault, 0)!
    CFStringAppend(mutable, input as CFString)
    guard CFStringTransform(mutable, nil, identifier as CFString, false) else {
      return nil
    }
    let output = mutable as String
    // ICU succeeds as a no-op when nothing matched. Treat that as "does not
    // apply" so the UI can disable the row instead of pretending it ran.
    return output == input ? nil : output
  }

  /// Title-cases each word. `String.titlecased()` does not exist on Swift String,
  /// so each whitespace-delimited word is capitalized and rejoined.
  static func titleCase(_ input: String) -> String {
    input
      .split(separator: " ", omittingEmptySubsequences: false)
      .map { word -> String in
        // Keep interior separators (hyphens, slashes) intact and title-case
        // each piece, matching what a user expects from "Title Case".
        word
          .split(separator: "-", omittingEmptySubsequences: false)
          .map { $0.capitalized }
          .joined(separator: "-")
      }
      .joined(separator: " ")
  }

  /// Upper-cases the first character and lower-cases the rest of the string.
  static func sentenceCase(_ input: String) -> String {
    guard let first = input.first else { return input }
    return first.uppercased() + input.dropFirst().lowercased()
  }

  static func togglingCase(_ input: String) -> String {
    String(input.map { character in
      character.isLowercase ? Character(character.uppercased()) : Character(character.lowercased())
    })
  }
}

extension StringTransform {
  /// `StringTransform` deliberately has no case-conversion cases in Swift, but
  /// ICU still understands these names. Exposed for completeness.
  static let lowercase = StringTransform(rawValue: "lowercase")
  static let uppercase = StringTransform(rawValue: "uppercase")
  static let capitalized = StringTransform(rawValue: "capitalized")
  static let toLatin = StringTransform(rawValue: "Any-Latin")
  static let latinToASCII = StringTransform(rawValue: "Any-Latin; Latin-ASCII")
  static let stripDiacritics = StringTransform(rawValue: "Any-Latin; Latin-ASCII")
}