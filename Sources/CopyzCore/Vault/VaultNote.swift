import Foundation

/// Encodes a clip as an Obsidian-compatible Markdown note.
///
/// Design constraint that makes the whole vault work: **a clip is immutable
/// once written.** That is why a folder in Dropbox or iCloud Drive can stand in
/// for a sync API — two machines writing the same clip produce byte-identical
/// files, two machines writing different clips produce different files, and
/// there is no merge case at all.
///
/// The metadata lives in YAML frontmatter and the payload lives in the body, so
/// the note is both machine-readable and pleasant to read in Obsidian.
public enum VaultNote {
  /// Current frontmatter schema version. Bumped when keys change meaning.
  public static let schemaVersion = 1

  public static func fileName(createdAt: Date, contentHash: String) -> String {
    let stamp = Self.makeTimestampFormatter().string(from: createdAt)
    let stem = String(contentHash.prefix(12))
    return "\(stamp)-\(stem).md"
  }

  public static func fileName(for item: ClipItem) -> String {
    fileName(createdAt: item.createdAt, contentHash: item.contentHash)
  }

  /// Relative path from the vault root, bucketed by day. Day buckets keep the
  /// per-directory entry count low, which matters for iCloud's metadata.
  public static func relativePath(createdAt: Date, contentHash: String) -> String {
    let calendar = Calendar(identifier: .gregorian)
    let parts = calendar.dateComponents([.year, .month, .day], from: createdAt)
    let day = String(format: "%02d", parts.day ?? 1)
    let month = String(format: "%02d", parts.month ?? 1)
    return "Clips/\(parts.year ?? 1970)/\(month)/\(day)/\(fileName(createdAt: createdAt, contentHash: contentHash))"
  }

  public static func relativePath(for item: ClipItem) -> String {
    relativePath(createdAt: item.createdAt, contentHash: item.contentHash)
  }

  public static func encode(_ item: ClipItem) -> String {
    var out = "---\n"

    out += "id: \(item.id.uuidString)\n"
    out += "ts: \(makeISOFormatter().string(from: item.createdAt))\n"
    out += "kind: \(item.kind.rawValue)\n"
    out += "sha256: \(item.contentHash)\n"

    if let app = item.sourceAppName, !app.isEmpty {
      out += "source_app: \(yamlQuoted(app))\n"
    }
    if let bundle = item.sourceBundleID, !bundle.isEmpty {
      out += "source_bundle_id: \(yamlQuoted(bundle))\n"
    }

    let types = item.contents.map(\.type).sorted()
    if !types.isEmpty {
      out += "pasteboard_types: [\(types.map { yamlQuoted($0) }.joined(separator: ", "))]\n"
    }

    let charCount = item.vaultBody.count
    out += "char_count: \(charCount)\n"
    out += "byte_count: \(item.contents.reduce(0) { $0 + $1.value.count })\n"
    out += "use_count: \(item.useCount)\n"
    if item.pinned { out += "pinned: true\n" }
    if let collection = item.collection, !collection.isEmpty {
      out += "collection: \(yamlQuoted(collection))\n"
    }

    // Asset pointer for binary kinds, so the note is never empty.
    if item.kind.isBinary, let asset = assetName(for: item) {
      out += "asset: \(yamlQuoted(asset))\n"
    }

    out += "schema: \(schemaVersion)\n"
    out += "---\n\n"

    let body = item.vaultBody
    if body.isEmpty, let asset = assetName(for: item) {
      out += "![[\(asset)]]\n"
    } else if item.kind.isBinary {
      out += "![[\(assetName(for: item) ?? "")]]\n\n"
      out += body
      if !body.hasSuffix("\n") { out += "\n" }
    } else {
      out += body
      if !body.hasSuffix("\n") { out += "\n" }
    }

    return out
  }

  /// Assets are content-addressed, so re-exporting the same clip reuses the
  /// same file rather than creating a duplicate.
  public static func assetName(for item: ClipItem) -> String? {
    guard item.kind.isBinary else { return nil }
    let stem = String(item.contentHash.prefix(12))
    guard let content = item.contents.first(where: { $0.type != PasteboardType.string.rawValue })
    else { return nil }
    let ext = Self.fileExtension(for: content.type)
    return "\(stem).\(ext)"
  }

  /// The bytes to write for a binary asset.
  public static func assetData(for item: ClipItem) -> Data? {
    guard item.kind.isBinary else { return nil }
    return item.contents.first { $0.type != PasteboardType.string.rawValue }?.value
  }

  static func fileExtension(for pasteboardType: String) -> String {
    switch PasteboardType(rawValue: pasteboardType) {
    case .png: "png"
    case .tiff: "tiff"
    case .jpeg: "jpg"
    case .heic: "heic"
    case .gif: "gif"
    case .pdf: "pdf"
    default: "bin"
    }
  }

  // MARK: - Parsing

  public struct Decoded: Sendable {
    public var id: UUID
    public var createdAt: Date
    public var kind: ClipKind
    public var contentHash: String
    public var sourceAppName: String?
    public var sourceBundleID: String?
    public var pinned: Bool
    public var collection: String?
    public var useCount: Int
    public var body: String
  }

  /// Reads a note written by `encode`. Returns nil when the file is not one of
  /// ours or its frontmatter is unusable, so a hand-written note in the vault
  /// is left alone rather than mangled.
  public static func decode(_ text: String) -> Decoded? {
    guard text.hasPrefix("---\n") else { return nil }
    guard let closingRange = text.range(of: "\n---\n", range: text.startIndex..<text.endIndex) else {
      return nil
    }

    let header = text[text.index(text.startIndex, offsetBy: 4)..<closingRange.lowerBound]
    let bodyStart = closingRange.upperBound
    let body = String(text[bodyStart...])

    var fields: [String: String] = [:]
    for line in header.split(separator: "\n") {
      guard let separator = line.firstIndex(of: ":") else { continue }
      let key = String(line[line.startIndex..<separator])
        .trimmingCharacters(in: .whitespaces)

      // Split on the *first* colon only, so a value containing `: "App"` is not
      // truncated, and unescape what `yamlQuoted` emitted.
      var value = String(line[line.index(after: separator)...])
        .trimmingCharacters(in: .whitespaces)
      if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
        var inner = String(value.dropFirst().dropLast())
        inner = inner.replacingOccurrences(of: "\\\"", with: "\"")
        inner = inner.replacingOccurrences(of: "\\n", with: "\n")
        inner = inner.replacingOccurrences(of: "\\\\", with: "\\")
        value = inner
      }
      fields[key] = value
    }

    guard let idString = fields["id"], let id = UUID(uuidString: idString),
          let hash = fields["sha256"],
          let kindRaw = fields["kind"], let kind = ClipKind(rawValue: kindRaw)
    else { return nil }

    let createdAt = fields["ts"].flatMap { makeISOFormatter().date(from: $0) } ?? Date()
    let pinned = fields["pinned"] == "true"
    let useCount = Int(fields["use_count"] ?? "") ?? 1

    return Decoded(
      id: id,
      createdAt: createdAt,
      kind: kind,
      contentHash: hash,
      sourceAppName: fields["source_app"],
      sourceBundleID: fields["source_bundle_id"],
      pinned: pinned,
      collection: fields["collection"],
      useCount: useCount,
      body: body.trimmingCharacters(in: .newlines)
    )
  }

  // MARK: - Formatting

  // `ISO8601DateFormatter` and `DateFormatter` are reference types with
  // mutable configuration, so caching them as globals is not concurrency-safe.
  // Both are cheap enough to build per call for this write volume.
  private static func makeISOFormatter() -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }

  private static func makeTimestampFormatter() -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
    return formatter
  }

  /// Double-quotes a YAML scalar, escaping anything that would break parsing.
  static func yamlQuoted(_ value: String) -> String {
    let escaped = value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\n", with: "\\n")
    return "\"\(escaped)\""
  }
}