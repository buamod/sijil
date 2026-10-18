import Foundation
import Testing

@testable import CopyzCore

@Suite("VaultWriter")
struct VaultWriterTests {
  private func makeVault() throws -> (VaultWriter, URL) {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "copyz-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (VaultWriter(rootURL: root), root)
  }

  private func cleanup(_ root: URL) {
    try? FileManager.default.removeItem(at: root)
  }

  private func textItem(_ text: String) -> ClipItem {
    ClipItem(contents: [ClipContent(type: PasteboardType.string.rawValue, value: Data(text.utf8))])
  }

  @Test("Prepare creates a vault that does not exist yet")
  func prepareCreatesMissingRoot() async throws {
    // Regression: a first run points at a fresh folder, and a bare existence
    // check made every later launch fail.
    let root = FileManager.default.temporaryDirectory
      .appending(path: "copyz-fresh-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { cleanup(root) }

    let writer = VaultWriter(rootURL: root)
    #expect(await writer.isReachable() == false)

    try await writer.prepare()
    #expect(await writer.isReachable() == true)

    let contents = try FileManager.default.contentsOfDirectory(atPath: root.path)
    #expect(contents.contains("Clips"))
    #expect(contents.contains("assets"))
  }

  @Test("Prepare is idempotent")
  func prepareIsIdempotent() async throws {
    let (writer, root) = try makeVault()
    defer { cleanup(root) }
    try await writer.prepare()
    try await writer.prepare()
    #expect(await writer.isReachable())
  }

  @Test("Writes a note into the day bucket")
  func writesNote() async throws {
    let (writer, root) = try makeVault()
    defer { cleanup(root) }
    try await writer.prepare()

    let item = textItem("written to vault")
    let relative = try await writer.write(item)

    let noteURL = root.appending(path: relative)
    #expect(FileManager.default.fileExists(atPath: noteURL.path))
    #expect(relative.hasPrefix("Clips/"))

    let text = try String(contentsOf: noteURL, encoding: .utf8)
    #expect(text.contains("written to vault"))
  }

  @Test("Binary clips land in assets/")
  func writesAssets() async throws {
    let (writer, root) = try makeVault()
    defer { cleanup(root) }
    try await writer.prepare()

    let item = ClipItem(contents: [
      ClipContent(type: PasteboardType.png.rawValue, value: Data([0x89, 0x50, 0x4E, 0x47])),
    ])
    try await writer.write(item)

    let files = try FileManager.default.contentsOfDirectory(
      atPath: root.appending(path: "assets").path
    )
    #expect(files.count == 1)
    #expect(files[0].hasSuffix(".png"))
  }

  @Test("Re-writing identical content does not duplicate the asset")
  func assetsAreIdempotent() async throws {
    let (writer, root) = try makeVault()
    defer { cleanup(root) }
    try await writer.prepare()

    let item = ClipItem(contents: [
      ClipContent(type: PasteboardType.png.rawValue, value: Data([1, 2, 3, 4])),
    ])
    try await writer.write(item)
    try await writer.write(item)

    let files = try FileManager.default.contentsOfDirectory(
      atPath: root.appending(path: "assets").path
    )
    #expect(files.count == 1)
  }

  @Test("Re-writing a note is byte-stable")
  func notesAreIdempotent() async throws {
    let (writer, root) = try makeVault()
    defer { cleanup(root) }
    try await writer.prepare()

    let item = textItem("stable bytes")
    let relative = try await writer.write(item)
    let first = try Data(contentsOf: root.appending(path: relative))
    try await writer.write(item)
    let second = try Data(contentsOf: root.appending(path: relative))
    // Byte-stability is what lets a synced folder resolve conflicts for free.
    #expect(first == second)
  }

  @Test("Read-back returns what was written")
  func readsBack() async throws {
    let (writer, root) = try makeVault()
    defer { cleanup(root) }
    try await writer.prepare()

    try await writer.write(textItem("findable content"))
    let decoded = await writer.readAll()
    #expect(decoded.count == 1)
    #expect(decoded.first?.body.contains("findable content") == true)
  }

  @Test("One unwritable item does not stall the batch")
  func batchIsFaultTolerant() async throws {
    let (writer, root) = try makeVault()
    defer { cleanup(root) }
    try await writer.prepare()

    let bad = textItem("this one cannot be written")

    // Block exactly this item by putting a directory where its note file must
    // go. Blocking the shared day bucket instead would fail *both* items, since
    // they are written moments apart on the same day.
    try FileManager.default.createDirectory(
      at: root.appending(path: VaultNote.relativePath(for: bad)),
      withIntermediateDirectories: true
    )

    let good = textItem("a second, unaffected clip")
    let written = await writer.writeBatch([bad, good])

    // Exactly one succeeded: the failure did not abort the batch.
    #expect(written.count == 1)
    #expect(written.first == good.id)
  }

  @Test("Missing vault reports unreachable rather than throwing on write")
  func handlesMissingRoot() async throws {
    // A *file* where the vault directory should be can never be created.
    let root = FileManager.default.temporaryDirectory
      .appending(path: "copyz-blocked-\(UUID().uuidString)")
    try Data("not a directory".utf8).write(to: root)
    defer { cleanup(root) }

    let writer = VaultWriter(rootURL: root.appending(path: "Vault", directoryHint: .isDirectory))
    #expect(await writer.isReachable() == false)
    #expect(await writer.readAll().isEmpty)

    await #expect(throws: VaultWriter.Failure.self) {
      try await writer.write(textItem("nope"))
    }
  }
}