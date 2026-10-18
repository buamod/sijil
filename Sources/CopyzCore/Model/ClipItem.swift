import Foundation

/// The semantic bucket a clip falls into. Derived from the pasteboard types
/// actually present, not from anything the source app declares about itself.
public enum ClipKind: String, Codable, Sendable, CaseIterable {
  case text
  case richText
  case html
  case link
  case color
  case emoji
  case image
  case file
  case files

  public var displayName: String {
    switch self {
    case .text: "Text"
    case .richText: "Rich Text"
    case .html: "HTML"
    case .link: "Link"
    case .color: "Color"
    case .emoji: "Emoji"
    case .image: "Image"
    case .file: "File"
    case .files: "Files"
    }
  }

  /// Whether this kind carries a binary payload that belongs in the vault's
  /// `assets/` directory rather than inline in the note body.
  public var isBinary: Bool {
    switch self {
    case .image, .file, .files: true
    case .text, .richText, .html, .link, .color, .emoji: false
    }
  }
}

/// One typed blob from the pasteboard. A single copy frequently produces
/// several of these — a link copied from Safari usually arrives as plain text,
/// HTML, and a URL simultaneously.
public struct ClipContent: Sendable, Hashable {
  public let type: String
  public let value: Data

  public init(type: String, value: Data) {
    self.type = type
    self.value = value
  }
}

/// A single clipboard history entry: everything that was on the pasteboard at
/// one moment, merged into one record.
public struct ClipItem: Sendable, Identifiable, Hashable {
  public let id: UUID
  public let createdAt: Date
  public var lastUsedAt: Date
  public var sourceBundleID: String?
  public var sourceAppName: String?
  public var contents: [ClipContent]
  public var pinned: Bool
  /// Stronger than `pinned`: survives a clear-history, like PastePal's
  /// `ZLOCKED`. Distinct because "I want this near the top" and "I must never
  /// lose this" are different intents, and conflating them makes clear-history
  /// either delete things the user relied on or be too weak to trust.
  public var locked: Bool
  /// Set once this clip has been deleted, so a vault import cannot resurrect it.
  public var tombstoned: Bool
  /// True only for items captured from the live pasteboard by the user.
  ///
  /// Vault import is read-only and cannot be trusted with resurrection rights,
  /// so it sets this false. A local capture setting it true is what allows
  /// re-copying previously deleted content, which is a legitimate new event
  /// rather than an undo of the delete.
  public var isFromLocalCapture: Bool
  public var collection: String?
  public var useCount: Int
  /// Cached, sanitized single-line preview. Recomputed on write; never trusted
  /// as a source of truth for the payload.
  public var title: String

  public init(
    id: UUID = UUID(),
    createdAt: Date = Date(),
    lastUsedAt: Date? = nil,
    sourceBundleID: String? = nil,
    sourceAppName: String? = nil,
    contents: [ClipContent] = [],
    pinned: Bool = false,
    locked: Bool = false,
    tombstoned: Bool = false,
    isFromLocalCapture: Bool = true,
    collection: String? = nil,
    useCount: Int = 1,
    title: String? = nil
  ) {
    self.id = id
    self.createdAt = createdAt
    self.lastUsedAt = lastUsedAt ?? createdAt
    self.sourceBundleID = sourceBundleID
    self.sourceAppName = sourceAppName
    self.contents = contents
    self.pinned = pinned
    self.locked = locked
    self.tombstoned = tombstoned
    self.isFromLocalCapture = isFromLocalCapture
    self.collection = collection
    self.useCount = useCount
    self.title = title ?? Self.makeTitle(from: contents)
  }

  /// Order-independent content hash. Two copies of identical content collapse
  /// to the same row; two machines syncing the same clip agree without talking
  /// to each other.
  public var contentHash: String {
    Digest.identity(of: contents)
  }

  // MARK: - Typed accessors

  public func data(for type: PasteboardType) -> Data? {
    contents.first { $0.type == type.rawValue }?.value
  }

  public func data(anyOf types: [PasteboardType]) -> Data? {
    for type in types {
      if let data = data(for: type) { return data }
    }
    return nil
  }

  public var plainText: String? {
    guard let data = data(for: .string) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  public var htmlData: Data? { data(for: .html) }
  public var rtfData: Data? { data(for: .rtf) }

  public var imageData: Data? {
    data(anyOf: [.png, .tiff, .jpeg, .heic, .gif])
  }

  /// File URLs as bytes, decoded. Multiple entries mean a multi-file copy.
  public var fileURLs: [URL] {
    contents
      .filter { $0.type == PasteboardType.fileURL.rawValue }
      .compactMap { URL(dataRepresentation: $0.value, relativeTo: nil, isAbsolute: true) }
  }

  public var hasMultipleFiles: Bool {
    contents.filter { $0.type == PasteboardType.fileURL.rawValue }.count > 1
  }

  // MARK: - Classification

  /// Dominant kind, richest representation first.
  public var kind: ClipKind {
    if hasMultipleFiles { return .files }
    if !fileURLs.isEmpty { return .file }
    if imageData != nil { return .image }
    if let text = plainText {
      if Self.isHexColor(text) { return .color }
      if Self.isEmojiOnly(text) { return .emoji }
      if let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
         url.scheme != nil,
         (text.contains("://") || url.scheme?.hasPrefix("mailto") == true) {
        return .link
      }
    }
    if data(for: .rtf) != nil || data(for: .rtfd) != nil { return .richText }
    if data(for: .html) != nil { return .html }
    return .text
  }

  /// `#AABBCC`, `#AABBCCDD`, `#RGB`, or the `rgb()`/`rgba()` CSS forms.
  static func isHexColor(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("#") {
      let hex = String(trimmed.dropFirst())
      let valid = hex.count == 3 || hex.count == 4 || hex.count == 6 || hex.count == 8
      return valid && hex.allSatisfy { $0.isHexDigit }
    }
    let lower = trimmed.lowercased()
    let isRGB = lower.hasPrefix("rgb(") || lower.hasPrefix("rgba(")
    if isRGB, let open = lower.firstIndex(of: "("), let close = lower.lastIndex(of: ")"), open < close {
      let parts = lower[lower.index(after: open)..<close].split(separator: ",")
      return (3...4).contains(parts.count) && parts.allSatisfy {
        $0.trimmingCharacters(in: .whitespaces).hasSuffix("%")
          || Double($0.trimmingCharacters(in: .whitespaces)) != nil
      }
    }
    return false
  }

  /// A clip that is a single grapheme cluster made only of emoji and its
  /// decorations. Deliberately conservative — a bare letter is not an emoji.
  static func isEmojiOnly(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 16 else { return false }
    var sawEmoji = false
    for cluster in trimmed.unicodeScalars {
      let value = cluster.value
      let isEmoji = (0x1F300...0x1FAFF).contains(value)
        || (0x2600...0x27BF).contains(value)
        || (0x2190...0x21FF).contains(value)
        || (0x2B00...0x2BFF).contains(value)
      if isEmoji { sawEmoji = true }
    }
    return sawEmoji
  }

  // MARK: - Title

  static func makeTitle(from contents: [ClipContent]) -> String {
    func text(of type: PasteboardType) -> String? {
      guard let data = contents.first(where: { $0.type == type.rawValue })?.value else { return nil }
      return String(data: data, encoding: .utf8)
    }

    // Richest textual representation available, so a link copied with HTML
    // still previews as the link rather than as markup.
    let candidate: String? =
      text(of: .string)
      ?? contents
        .first { $0.type == PasteboardType.rtf.rawValue || $0.type == PasteboardType.rtfd.rawValue }
        .flatMap { NSAttributedString(rtf: $0.value, documentAttributes: nil)?.string }
      ?? contents
        .first { $0.type == PasteboardType.html.rawValue }
        .flatMap { NSAttributedString(html: $0.value, documentAttributes: nil)?.string }
      ?? contents
        .filter { $0.type == PasteboardType.fileURL.rawValue }
        .compactMap { URL(dataRepresentation: $0.value, relativeTo: nil, isAbsolute: true)?.lastPathComponent }
        .first

    guard let candidate, !candidate.isEmpty else { return "" }
    return TextSanitizer.previewLine(candidate)
  }

  /// Full text payload for the vault note body. Unlike `title` this is never
  /// truncated — the vault note is the durable record.
  public var vaultBody: String {
    if let plainText { return plainText }
    if let htmlData,
       let attributed = NSAttributedString(html: htmlData, documentAttributes: nil),
       !attributed.string.isEmpty {
      return attributed.string
    }
    if let rtfData,
       let attributed = NSAttributedString(rtf: rtfData, documentAttributes: nil),
       !attributed.string.isEmpty {
      return attributed.string
    }
    if !fileURLs.isEmpty {
      return fileURLs.map(\.path).joined(separator: "\n")
    }
    return title
  }
}