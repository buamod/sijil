import AppKit
import Foundation

/// Writes a stored clip back onto the system pasteboard.
@MainActor
public enum PasteboardWriter {
  /// Restores `item` onto `pasteboard`, stamping our marker type so the monitor
  /// can tell the write apart from a user copy.
  ///
  /// - Parameter plainTextOnly: drop rich representations, keeping only the
  ///   plain string and any file URLs — the "paste without formatting" action.
  @discardableResult
  public static func write(
    _ item: ClipItem,
    to pasteboard: NSPasteboard = .general,
    plainTextOnly: Bool = false
  ) -> Bool {
    var contents = item.contents

    if plainTextOnly {
      let strings = contents.filter { $0.type == PasteboardType.string.rawValue }
      let fileURLs = contents.filter { $0.type == PasteboardType.fileURL.rawValue }
      // If there is no plain-text representation there is nothing to strip.
      contents = strings.isEmpty ? contents : strings + fileURLs
    }

    pasteboard.clearContents()

    var wroteAnything = false
    for content in contents where content.type != PasteboardType.fileURL.rawValue {
      guard pasteboard.setData(content.value, forType: NSPasteboard.PasteboardType(content.type)) else {
        continue
      }
      wroteAnything = true
    }

    // File URLs must go through `writeObjects` rather than `setData`: copying
    // ten files in Finder produces ten pasteboard items, and `setData` would
    // collapse them into a single item pointing at the last one.
    //
    // Restricted to file URLs — `writeObjects` re-pastes other types twice in
    // some apps.
    let fileItems: [NSPasteboardItem] = contents.compactMap { content in
      guard content.type == PasteboardType.fileURL.rawValue else { return nil }
      let pasteboardItem = NSPasteboardItem()
      pasteboardItem.setData(content.value, forType: .fileURL)
      return pasteboardItem
    }
    if !fileItems.isEmpty {
      pasteboard.writeObjects(fileItems)
      wroteAnything = true
    }

    // Empty string, but presence is the signal — that is what the monitor
    // checks for.
    pasteboard.setString("", forType: .selfMarker)
    pasteboard.setString(item.sourceBundleID ?? "", forType: NSPasteboard.PasteboardType("org.nspasteboard.source"))

    return wroteAnything
  }
}

private extension NSPasteboard.PasteboardType {
  static let selfMarker = NSPasteboard.PasteboardType(PasteboardType.selfMarker.rawValue)
}