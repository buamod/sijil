import Foundation
import Testing

@testable import SijilCore

@Suite("Digest")
struct DigestTests {
  private func content(_ type: String, _ value: String) -> ClipContent {
    ClipContent(type: type, value: Data(value.utf8))
  }

  @Test("Identity is order-independent")
  func identityIsOrderIndependent() {
    let a = content("public.utf8-plain-text", "hello")
    let b = content("public.html", "<b>hello</b>")
    #expect(Digest.identity(of: [a, b]) == Digest.identity(of: [b, a]))
  }

  @Test("Identity differs when content differs")
  func identityDiffersOnContent() {
    let a = content("public.utf8-plain-text", "hello")
    let b = content("public.utf8-plain-text", "world")
    #expect(Digest.identity(of: [a]) != Digest.identity(of: [b]))
  }

  @Test("Identity differs when only the type differs")
  func identityDiffersOnType() {
    let a = content("public.utf8-plain-text", "hello")
    let b = content("public.utf16-plain-text", "hello")
    #expect(Digest.identity(of: [a]) != Digest.identity(of: [b]))
  }
}
