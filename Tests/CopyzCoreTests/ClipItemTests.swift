import Foundation
import Testing

@testable import CopyzCore

@Suite("ClipItem classification")
struct ClipItemTests {
  private func text(_ value: String) -> ClipItem {
    ClipItem(contents: [
      ClipContent(type: PasteboardType.string.rawValue, value: Data(value.utf8))
    ])
  }

  @Test("Plain text classifies as text")
  func plainText() {
    #expect(text("hello").kind == .text)
  }

  @Test("Hex colors are recognised in every length")
  func hexColors() {
    for value in ["#ABC", "#ABCD", "#AABBCC", "#AABBCCDD"] {
      #expect(text(value).kind == .color, "\(value) should be a color")
    }
    // Not a color.
    #expect(text("#GGGGGG").kind == .text)
    #expect(text("#AABBCCEEFF").kind == .text)
  }

  @Test("CSS rgb() forms are recognised")
  func rgbColors() {
    #expect(text("rgb(255, 0, 0)").kind == .color)
    #expect(text("rgba(255, 0, 0, 0.5)").kind == .color)
    #expect(text("rgb(100%, 0%, 0%)").kind == .color)
    #expect(text("rgb(not a color)").kind == .text)
  }

  @Test("Emoji-only text is recognised")
  func emoji() {
    #expect(text("🎉").kind == .emoji)
    #expect(text("🎉").kind != .text)
  }

  @Test("URLs classify as links")
  func links() {
    #expect(text("https://example.com").kind == .link)
    #expect(text("http://example.com/path?q=1").kind == .link)
    #expect(text("not a url").kind == .text)
  }

  @Test("Image payloads classify as images")
  func images() {
    let item = ClipItem(contents: [
      ClipContent(type: PasteboardType.png.rawValue, value: Data([0x89, 0x50]))
    ])
    #expect(item.kind == .image)
  }

  @Test("RTF without plain text is rich text")
  func richText() {
    let attributed = NSAttributedString(string: "formatted")
    let rtf = try? attributed.data(
      from: NSRange(location: 0, length: attributed.length),
      documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
    )
    guard let rtf else { return }
    let item = ClipItem(contents: [
      ClipContent(type: PasteboardType.rtf.rawValue, value: rtf)
    ])
    #expect(item.kind == .richText)
  }

  @Test("Multiple file URLs classify as files")
  func multipleFiles() {
    let a = URL(fileURLWithPath: "/tmp/a.txt")
    let b = URL(fileURLWithPath: "/tmp/b.txt")
    let item = ClipItem(contents: [
      ClipContent(type: PasteboardType.fileURL.rawValue, value: a.dataRepresentation),
      ClipContent(type: PasteboardType.fileURL.rawValue, value: b.dataRepresentation),
    ])
    #expect(item.kind == .files)
    #expect(item.fileURLs.count == 2)
  }

  @Test("A single file classifies as a file, not files")
  func singleFile() {
    let url = URL(fileURLWithPath: "/tmp/only.txt")
    let item = ClipItem(contents: [
      ClipContent(type: PasteboardType.fileURL.rawValue, value: url.dataRepresentation)
    ])
    #expect(item.kind == .file)
  }

  @Test("Binary kinds are flagged for the vault")
  func binaryKinds() {
    #expect(ClipKind.image.isBinary)
    #expect(ClipKind.file.isBinary)
    #expect(ClipKind.files.isBinary)
    #expect(ClipKind.text.isBinary == false)
    #expect(ClipKind.link.isBinary == false)
  }

  @Test("Titles are single-line previews")
  func titleIsPreview() {
    let item = text("line one\nline two")
    #expect(item.title == "line one line two")
  }

  @Test("Vault body preserves the full payload")
  func vaultBodyIsFull() {
    let long = String(repeating: "word ", count: 2_000)
    let item = text(long)
    #expect(item.vaultBody == long)
    // The title is capped but the body is not.
    #expect(item.title.count <= TextSanitizer.maxTitleScalars)
  }

  @Test("The richest textual representation wins for the title")
  func richestRepresentationWins() {
    // A link copied from Safari arrives as text plus HTML.
    let item = ClipItem(contents: [
      ClipContent(type: PasteboardType.string.rawValue, value: Data("https://example.com".utf8)),
      ClipContent(
        type: PasteboardType.html.rawValue,
        value: Data("<a href='https://example.com'>Example</a>".utf8)
      ),
    ])
    #expect(item.title == "https://example.com")
  }

  @Test("Content hash is stable across equivalent items")
  func hashIsStable() {
    let a = ClipItem(contents: [
      ClipContent(type: PasteboardType.string.rawValue, value: Data("x".utf8)),
      ClipContent(type: PasteboardType.html.rawValue, value: Data("y".utf8)),
    ])
    let b = ClipItem(contents: [
      ClipContent(type: PasteboardType.html.rawValue, value: Data("y".utf8)),
      ClipContent(type: PasteboardType.string.rawValue, value: Data("x".utf8)),
    ])
    #expect(a.contentHash == b.contentHash)
  }
}

@Suite("PasteboardType")
struct PasteboardTypeTests {
  @Test("Unknown types are recognised as unknown rather than crashing")
  func unknownTypesAreSafe() {
    #expect(PasteboardType(rawValue: "com.example.unheard-of") == nil)
    #expect(PasteboardType.isKnown("com.example.unheard-of") == false)
    #expect(PasteboardType.isKnown(PasteboardType.string.rawValue))
  }

  @Test("Web archives are never persisted")
  func webArchivesNotPersistable() {
    #expect(PasteboardType.isPersistable(PasteboardType.appleWebArchive.rawValue) == false)
    #expect(PasteboardType.isPersistable(PasteboardType.safariWebArchive.rawValue) == false)
    #expect(PasteboardType.isPersistable(PasteboardType.string.rawValue))
  }

  @Test("Engine-state types are dropped by prefix")
  func engineStateDropped() {
    // Writing Tools dynamic state (macOS 15+) and Word bookmark plumbing.
    #expect(PasteboardType.isPersistable("dyn.ah62d3b4c5") == false)
    #expect(PasteboardType.isPersistable("com.microsoft.ole.source.1234") == false)
  }

  @Test("Unknown but plausible types are kept")
  func unknownTypesKept() {
    #expect(PasteboardType.isPersistable("com.example.custom") == true)
  }

  @Test("Privacy markers are the documented three")
  func privacyMarkers() {
    #expect(PasteboardType.privacyMarkers.count == 3)
    #expect(PasteboardType.privacyMarkers.contains(.concealed))
    #expect(PasteboardType.privacyMarkers.contains(.transient))
    #expect(PasteboardType.privacyMarkers.contains(.autoGenerated))
  }
}
