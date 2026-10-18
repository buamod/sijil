import AppKit
import Foundation
import Testing

@testable import CopyzCore

@Suite("ClipPreview")
struct ClipPreviewTests {
  private func text(_ value: String) -> ClipItem {
    ClipItem(contents: [
      ClipContent(type: PasteboardType.string.rawValue, value: Data(value.utf8)),
    ])
  }

  @Test("Text preview returns plain text unchanged")
  func plainTextPreview() {
    #expect(ClipPreview.text(for: text("hello")) == "hello")
  }

  @Test("Text preview falls back to HTML when there is no plain text")
  func htmlFallback() {
    let item = ClipItem(contents: [
      ClipContent(
        type: PasteboardType.html.rawValue,
        value: Data("<b>bold</b> text".utf8)
      ),
    ])
    #expect(ClipPreview.text(for: item) == "bold text")
  }

  @Test("Text preview lists file paths")
  func fileFallback() {
    let url = URL(fileURLWithPath: "/tmp/report.pdf")
    let item = ClipItem(contents: [
      ClipContent(type: PasteboardType.fileURL.rawValue, value: url.dataRepresentation),
    ])
    #expect(ClipPreview.text(for: item) == "/tmp/report.pdf")
  }

  @Test("Attributed text is produced for plain clips")
  func attributedText() {
    let attributed = ClipPreview.attributedText(for: text("hello"))
    #expect(attributed?.string == "hello")
  }

  @Test("Colour parsing accepts every hex length")
  func hexColors() {
    let full = NSColor(cssHex: "#AABBCC")
    #expect(full != nil)

    // 0xDD is 221, so alpha is 221/255 — opaque-ish but not fully opaque, which is
// what proves the alpha byte was read rather than ignored.
    let rgba = NSColor(cssHex: "#AABBCCDD")
    #expect(rgba != nil)
    let alpha = rgba?.alphaComponent ?? 0
    #expect(abs(alpha - 0xDD / 255) < 0.001)

    // Shorthand expands, so #ABC must equal #AABBCC.
    let short = NSColor(cssHex: "#ABC")
    #expect(short != nil)
    #expect(abs((short?.redComponent ?? 0) - 0xAA / 255) < 0.01)

    // Whitespace tolerated.
    #expect(NSColor(cssHex: "  #AABBCC  ") != nil)
  }

  @Test("Colour parsing rejects junk")
  func rejectsJunk() {
    #expect(NSColor(cssHex: "#GGGGGG") == nil)
    #expect(NSColor(cssHex: "#AABBCCEEFF") == nil)
    #expect(NSColor(cssHex: "") == nil)
    #expect(NSColor(cssHex: "not a color") == nil)
    #expect(NSColor(cssHex: "rgb()") == nil)
    #expect(NSColor(cssHex: "rgb(1,2)") == nil)
    #expect(NSColor(cssHex: "rgb(a,b,c)") == nil)
  }

  @Test("RGB functional forms parse")
  func rgbColors() {
    #expect(NSColor(cssHex: "rgb(255, 0, 0)") != nil)
    #expect(NSColor(cssHex: "rgba(255, 0, 0, 0.5)") != nil)
    #expect(NSColor(cssHex: "rgb(100%, 0%, 0%)") != nil)

    // Regression: alpha was scaled like a colour channel, so rgba(0,0,0,0.5)
    // came out 0.002 — visually opaque instead of half transparent.
    let half = NSColor(cssHex: "rgba(0, 0, 0, 0.5)")
    #expect(half != nil)
    let alpha = half?.alphaComponent ?? 1
    #expect(abs(alpha - 0.5) < 0.01, "alpha was \(alpha), expected ~0.5")

    // Percentage alpha too.
    let quarter = NSColor(cssHex: "rgba(0, 0, 0, 25%)")
    #expect(abs((quarter?.alphaComponent ?? 1) - 0.25) < 0.01)

    // Alpha-free rgb() is fully opaque.
    #expect(abs((NSColor(cssHex: "rgb(0,0,0)")?.alphaComponent ?? 0) - 1) < 0.01)
  }

  @Test("Colour preview only applies to colour clips")
  func colorPreviewOnlyForColors() {
    #expect(ClipPreview.color(for: text("#AABBCC")) != nil)
    #expect(ClipPreview.color(for: text("hello")) == nil)
  }

  @Test("Image preview decodes image payloads")
  func imagePreview() {
    // A 1x1 transparent PNG.
    let base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
    guard let data = Data(base64Encoded: base64) else {
      Issue.record("bad fixture")
      return
    }
    let item = ClipItem(contents: [
      ClipContent(type: PasteboardType.png.rawValue, value: data),
    ])
    #expect(ClipPreview.image(for: item) != nil)
    #expect(ClipPreview.image(for: text("not an image")) == nil)
  }

  @Test("Preview never traps on empty or odd items")
  func robustOnOddItems() {
    let empty = ClipItem(contents: [])
    #expect(ClipPreview.text(for: empty) == nil)
    #expect(ClipPreview.image(for: empty) == nil)
    #expect(ClipPreview.color(for: empty) == nil)
    #expect(ClipPreview.attributedText(for: empty) == nil)

    let garbage = ClipItem(contents: [
      ClipContent(type: PasteboardType.png.rawValue, value: Data([0xFF, 0x00, 0xFF])),
      ClipContent(type: PasteboardType.rtf.rawValue, value: Data("not rtf at all".utf8)),
    ])
    // Must return, not crash.
    _ = ClipPreview.text(for: garbage)
    _ = ClipPreview.image(for: garbage)
    _ = ClipPreview.attributedText(for: garbage)
  }
}