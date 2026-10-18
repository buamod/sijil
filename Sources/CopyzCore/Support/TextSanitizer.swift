import Foundation

/// Guards against text that makes CoreText spin forever.
///
/// macOS 26 regressed here badly: a title containing certain scalars can hang
/// the text engine at 100% CPU during layout, which in a clipboard manager means
/// the app locks up before it ever draws a window — and the offending title is
/// persisted, so it hangs again on every subsequent launch. See p0deje/Maccy
/// #1520. We sanitize on the way in and keep a repair path for old rows.
enum TextSanitizer {
  private static func inserting(_ range: ClosedRange<UInt32>, into set: inout Set<Unicode.Scalar>) {
    for value in range {
      if let scalar = Unicode.Scalar(value) { set.insert(scalar) }
    }
  }

  /// Longest run of "formatting" scalars allowed to sit together. Emoji
  /// sequences legitimately reach ~5; pathological input chains them
  /// thousands deep and that is what wedges CoreText.
  private static let maxDecorationRun = 16

  /// Titles are a preview, not a payload. The full text always lives in the
  /// item body and in the vault note.
  static let maxTitleScalars = 1_000

  private static let decorations: Set<Unicode.Scalar> = {
    var set = Set<Unicode.Scalar>([
      "\u{200D}", // ZERO WIDTH JOINER
      "\u{FE0F}", // VARIATION SELECTOR-16 (emoji presentation)
      "\u{FE0E}", // VARIATION SELECTOR-15 (text presentation)
      "\u{20E3}", // COMBINING ENCLOSING KEYCAP
    ])
    inserting(0xE0020...0xE007F, into: &set) // emoji flag tag characters
    inserting(0x0300...0x036F, into: &set) // combining diacritics
    inserting(0x1AB0...0x1AFF, into: &set) // combining marks, extended
    inserting(0x20D0...0x20FF, into: &set) // combining marks for symbols
    inserting(0xFE20...0xFE2F, into: &set) // combining half marks
    return set
  }()

  /// Scalars CoreText cannot lay out at all.
  private static func isFatal(_ scalar: Unicode.Scalar) -> Bool {
    // C0/C1 controls, except the ones we render deliberately.
    if scalar.value < 0x20, scalar != "\n", scalar != "\t" { return true }
    if scalar.value >= 0x7F, scalar.value <= 0x9F { return true }
    // Noncharacters.
    if (scalar.value & 0xFFFE) == 0xFFFE { return true }
    if (scalar.value & 0xFFFF) == 0xFFFE || (scalar.value & 0xFFFF) == 0xFFFF { return true }
    // Surrogates cannot appear in a valid Swift String, but a mangled decode
    // can leave U+FFFD behind, which renders as a tofu box in a title.
    if scalar == "\u{FFFD}" { return true }
    return false
  }

  /// Removes scalars unsafe for title layout, collapsing runaway decoration runs.
  static func sanitizeForTitle(_ input: String) -> String {
    var output = String.UnicodeScalarView()
    output.reserveCapacity(input.unicodeScalars.count)
    var runLength = 0

    for scalar in input.unicodeScalars {
      if isFatal(scalar) { continue }
      if decorations.contains(scalar) {
        runLength += 1
        if runLength > maxDecorationRun { continue }
      } else {
        runLength = 0
      }
      output.append(scalar)
      if output.count >= maxTitleScalars { break }
    }

    return truncateOnGraphemeBoundary(output)
  }

  private static func truncateOnGraphemeBoundary(_ view: String.UnicodeScalarView) -> String {
    var result = String(view)
    while !result.isEmpty, result.unicodeScalars.count > maxTitleScalars {
      result.removeLast()
    }
    return result
  }

  /// Single-line, whitespace-collapsed preview used for list rows.
  static func previewLine(_ input: String, limit: Int = 1_000) -> String {
    var scalars: [Unicode.Scalar] = []
    var pendingWhitespace = false
    for scalar in sanitizeForTitle(input).unicodeScalars {
      if isFatal(scalar) { continue }
      if scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" {
        pendingWhitespace = !scalars.isEmpty
        continue
      }
      if pendingWhitespace {
        scalars.append(" ")
        pendingWhitespace = false
      }
      scalars.append(scalar)
      if scalars.count >= limit { break }
    }
    return String(String.UnicodeScalarView(scalars))
  }
}