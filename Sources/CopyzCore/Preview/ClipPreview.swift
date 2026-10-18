import AppKit
import Foundation
import QuickLookThumbnailing

/// Produces a preview for a clip.
///
/// Rich content is decoded on demand rather than at capture time: RTF and image
/// decoding are the expensive part of a copy, and the history list only needs
/// the text preview. Decoding 50 thumbnails lazily keeps capture instant.
public enum ClipPreview {
  public enum Failure: LocalizedError {
    case unsupported

    public var errorDescription: String? {
      "No preview available for this kind of item."
    }
  }

  /// Plain-text preview, best representation first.
  public static func text(for item: ClipItem) -> String? {
    if let text = item.plainText, !text.isEmpty { return text }
    if let rtf = item.rtfData,
       let attributed = NSAttributedString(rtf: rtf, documentAttributes: nil),
       !attributed.string.isEmpty {
      return attributed.string
    }
    if let html = item.htmlData,
       let attributed = NSAttributedString(html: html, documentAttributes: nil),
       !attributed.string.isEmpty {
      return attributed.string
    }
    if !item.fileURLs.isEmpty {
      return item.fileURLs.map(\.path).joined(separator: "\n")
    }
    return nil
  }

  /// Attributed text for rich rendering, when the clip carries formatting.
  public static func attributedText(for item: ClipItem) -> NSAttributedString? {
    if let rtf = item.rtfData {
      return NSAttributedString(rtf: rtf, documentAttributes: nil)
    }
    if let html = item.htmlData {
      return NSAttributedString(html: html, documentAttributes: nil)
    }
    if let text = item.plainText {
      return NSAttributedString(string: text)
    }
    return nil
  }

  public static func image(for item: ClipItem) -> NSImage? {
    guard let data = item.imageData else { return nil }
    return NSImage(data: data)
  }

  /// A colour swatch for hex-colour clips.
  public static func color(for item: ClipItem) -> NSColor? {
    guard item.kind == .color, let text = item.plainText else { return nil }
    return NSColor(cssHex: text)
  }

  /// A QuickLook thumbnail for file clips, using the system generator so the
  /// preview matches Finder.
  public static func thumbnail(
    for url: URL,
    size: CGSize = CGSize(width: 64, height: 64),
    completion: @escaping @Sendable (NSImage?) -> Void
  ) {
    let request = QLThumbnailGenerator.Request(
      fileAt: url,
      size: size,
      scale: NSScreen.main?.backingScaleFactor ?? 2,
      representationTypes: .thumbnail
    )

    QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
      // The representation carries an NSImage; no CGImage round trip needed.
      completion(representation?.nsImage)
    }
  }
}

extension NSColor {
  /// Parses `#RGB`, `#RGBA`, `#RRGGBB`, `#RRGGBBAA`, `rgb()`, and `rgba()`.
  convenience init?(cssHex input: String) {
    let text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

    if text.hasPrefix("#") {
      let hex = String(text.dropFirst())
      guard hex.allSatisfy({ $0.isHexDigit }) else { return nil }
      // Expand the shorthand form so one parse path covers every length.
      let expanded: String
      switch hex.count {
      case 3, 4: expanded = hex.map { "\($0)\($0)" }.joined()
      case 6, 8: expanded = hex
      default: return nil
      }
      guard
        let value = UInt64(expanded, radix: 16)
      else { return nil }

      let hasAlpha = expanded.count == 8
      let red = Double((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
      let green = Double((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
      let blue = Double((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
      let alpha = hasAlpha ? Double(value & 0xFF) / 255 : 1
      self.init(srgbRed: red, green: green, blue: blue, alpha: alpha)
      return
    }

    guard text.hasPrefix("rgb"), let open = text.firstIndex(of: "("),
          let close = text.lastIndex(of: ")"), open < close
    else { return nil }

    let parts = text[text.index(after: open)..<close]
      .split(separator: ",", omittingEmptySubsequences: true)
      .map { $0.trimmingCharacters(in: .whitespaces) }
    guard (3...4).contains(parts.count) else { return nil }

    /// Colour channels accept both `0..255` and percentage forms.
    func component(_ part: String) -> CGFloat? {
      if part.hasSuffix("%") {
        guard let value = Double(part.dropLast()) else { return nil }
        return CGFloat(value / 100)
      }
      guard let value = Double(part) else { return nil }
      return CGFloat(value / 255)
    }

    /// Alpha is already `0..1` in CSS — it must not be scaled like a colour
    /// channel, or `rgba(0,0,0,0.5)` comes out essentially opaque.
    func alphaComponent(_ part: String) -> CGFloat? {
      if part.hasSuffix("%") {
        guard let value = Double(part.dropLast()) else { return nil }
        return CGFloat(value / 100)
      }
      guard let value = Double(part) else { return nil }
      return CGFloat(value)
    }

    guard
      let red = component(parts[0]),
      let green = component(parts[1]),
      let blue = component(parts[2])
    else { return nil }

    let alpha = parts.count == 4 ? (alphaComponent(parts[3]) ?? 1) : 1
    self.init(srgbRed: red, green: green, blue: blue, alpha: alpha)
  }
}