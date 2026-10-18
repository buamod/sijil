import AppKit
import Foundation

/// Turns a raw pasteboard read into a single `ClipItem`.
///
/// One user copy frequently produces *several* `NSPasteboardItem`s — copying
/// ten files in Finder yields ten, and BBEdit/Edge emit two per copy for a
/// single selection. Those all belong to one history row, so everything here
/// merges into one item rather than emitting one per pasteboard item.
public enum PasteboardExtractor {
  /// Types we never read bytes for, regardless of what the source advertises.
  /// Microsoft Word puts bookmark and cross-reference plumbing on the
  /// pasteboard that is never what the user meant to copy.
  private static let microsoftNoise: Set<String> = [
    PasteboardType.microsoftLinkSource.rawValue,
    PasteboardType.microsoftObjectLink.rawValue,
  ]

  @MainActor
  public static func makeItem(
    from pasteboardItems: [NSPasteboardItem],
    sourceBundleID: String?,
    sourceAppName: String?,
    rules: CaptureRules,
    patterns: CompiledPatterns,
    now: Date = Date()
  ) -> (item: ClipItem, rejection: CaptureRules.Rejection?)? {
    // Snapshot the advertised types once. `NSPasteboard.types` reports the
    // union of every type the pasteboard server could convert to, including
    // types not actually present on any item — so `pasteboardItems` is the
    // authoritative source and `types` is only a cheap pre-filter.
    let advertised = Set(pasteboardItems.flatMap { $0.types.map(\.rawValue) })

    if let rejection = rules.rejection(
      types: advertised,
      bundleID: sourceBundleID,
      text: nil,
      patterns: patterns
    ) {
      return (ClipItem(contents: []), rejection)
    }

    var contents: [ClipContent] = []

    for pasteboardItem in pasteboardItems {
      var types = Set(pasteboardItem.types.map(\.rawValue))

      // An empty string alongside no rich payload is a placeholder, not a copy.
      // But an empty string *with* rich text is legitimate (e.g. an image-only
      // rich paste), so only drop it when nothing else is there.
      if types.contains(PasteboardType.string.rawValue),
         isBlankString(pasteboardItem),
         !hasRichPayload(pasteboardItem) {
        continue
      }

      if let text = pasteboardItem.string(forType: .string),
         !text.isEmpty,
         patterns.matches(text) {
        return (ClipItem(contents: []), .patternMatched)
      }

      types = types.filter { PasteboardType.isPersistable($0) }

      // Drop Word bookmark plumbing when it is a superset of the real payload.
      if Set(microsoftNoise).isSubset(of: types), types.count > microsoftNoise.count {
        types.subtract(microsoftNoise)
        types.remove(PasteboardType.pdf.rawValue)
      }

      if !rules.capturesImages, !types.isDisjoint(with: PasteboardType.imageKinds.rawValues) {
        types.subtract(PasteboardType.imageKinds.rawValues)
      }

      for type in types.sorted() {
        guard let data = pasteboardItem.data(forType: NSPasteboard.PasteboardType(type)),
              !data.isEmpty
        else { continue }
        contents.append(ClipContent(type: type, value: data))
      }
    }

    guard !contents.isEmpty else { return nil }

    let item = ClipItem(
      createdAt: now,
      lastUsedAt: now,
      sourceBundleID: sourceBundleID,
      sourceAppName: sourceAppName,
      contents: contents
    )
    return (item, nil)
  }

  @MainActor
  private static func isBlankString(_ item: NSPasteboardItem) -> Bool {
    guard let string = item.string(forType: .string) else { return true }
    return string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  @MainActor
  private static func hasRichPayload(_ item: NSPasteboardItem) -> Bool {
    if let rtf = item.data(forType: .rtf),
       let attributed = NSAttributedString(rtf: rtf, documentAttributes: nil),
       !attributed.string.isEmpty {
      return true
    }
    if let html = item.data(forType: .html),
       let attributed = NSAttributedString(html: html, documentAttributes: nil),
       !attributed.string.isEmpty {
      return true
    }
    return false
  }
}