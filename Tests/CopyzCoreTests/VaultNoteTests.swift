import Foundation
import Testing

@testable import CopyzCore

@Suite("VaultNote")
struct VaultNoteTests {
  private func textItem(_ text: String, source: String? = nil) -> ClipItem {
    ClipItem(
      sourceBundleID: source,
      sourceAppName: source,
      contents: [ClipContent(type: PasteboardType.string.rawValue, value: Data(text.utf8))]
    )
  }

  @Test("Frontmatter starts on line one")
  func frontmatterIsFirstLine() {
    // Obsidian treats frontmatter as properties only when it is line 1, with no
    // leading blank line.
    let note = VaultNote.encode(textItem("hello"))
    #expect(note.hasPrefix("---\n"))
  }

  @Test("Body holds the payload verbatim, not a fence")
  func bodyIsVerbatim() {
    let note = VaultNote.encode(textItem("line one\nline two"))
    #expect(note.contains("line one\nline two"))
    #expect(!note.contains("```"))
  }

  @Test("Round-trips through decode")
  func roundTrip() throws {
    let original = textItem("round trip me", source: "com.apple.Safari")
    let decoded = try #require(VaultNote.decode(VaultNote.encode(original)))

    #expect(decoded.id == original.id)
    #expect(decoded.contentHash == original.contentHash)
    #expect(decoded.sourceAppName == "com.apple.Safari")
    #expect(decoded.body == "round trip me")
  }

  @Test("Re-encoding is byte-stable")
  func encodingIsDeterministic() {
    // Immutability is what makes folder sync conflict-free, so the same clip
    // must always produce the same bytes.
    let item = textItem("stable", source: "Safari")
    #expect(VaultNote.encode(item) == VaultNote.encode(item))
  }

  @Test("Path is bucketed by day")
  func pathIsDayBucketed() {
    let item = textItem("x")
    let path = VaultNote.relativePath(for: item)
    #expect(path.hasPrefix("Clips/"))
    #expect(path.hasSuffix(".md"))
    // Clips/YYYY/MM/DD/<filename>
    #expect(path.split(separator: "/").count == 5)
  }

  @Test("YAML-hostile source names stay parseable")
  func quotesHostileValues() {
    let item = textItem("x", source: "Weird: \"App\" #1")
    let note = VaultNote.encode(item)
    let decoded = try? VaultNote.decode(note)
    #expect(decoded?.sourceAppName == "Weird: \"App\" #1")
  }

  @Test("Non-note files are ignored")
  func rejectsForeignContent() {
    #expect(VaultNote.decode("# Just a markdown heading") == nil)
    #expect(VaultNote.decode("no frontmatter at all") == nil)
    #expect(VaultNote.decode("---\nno closing fence\n") == nil)
  }

  @Test("Binary clips get an asset and an embed")
  func binaryClipsReferenceAssets() throws {
    let item = ClipItem(contents: [
      ClipContent(type: PasteboardType.png.rawValue, value: Data([0x89, 0x50, 0x4E, 0x47])),
    ])
    let note = VaultNote.encode(item)

    #expect(note.contains("asset:"))
    #expect(note.contains("![["))

    let assetName = try #require(VaultNote.assetName(for: item))
    #expect(assetName.hasSuffix(".png"))
    #expect(VaultNote.assetData(for: item) != nil)
  }

  @Test("Asset names are content-addressed")
  func assetsAreContentAddressed() throws {
    let first = ClipItem(contents: [
      ClipContent(type: PasteboardType.png.rawValue, value: Data([1, 2, 3])),
    ])
    let second = ClipItem(contents: [
      ClipContent(type: PasteboardType.png.rawValue, value: Data([1, 2, 3])),
    ])
    #expect(VaultNote.assetName(for: first) == VaultNote.assetName(for: second))
  }

  @Test("Text clips carry no asset")
  func textClipsHaveNoAsset() {
    #expect(VaultNote.assetName(for: textItem("plain")) == nil)
  }
}