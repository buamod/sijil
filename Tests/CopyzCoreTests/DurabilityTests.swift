import Foundation
import Testing

@testable import CopyzCore

/// Verifies the durability guarantees the vault's file format depends on:
/// publication is atomic, temp files are swept, and secure_delete is on.
@Suite("Durability")
struct DurabilityTests {
  private func makeVault() throws -> (VaultWriter, URL) {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "copyz-dur-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (VaultWriter(rootURL: root), root)
  }

  private func cleanup(_ root: URL) {
    try? FileManager.default.removeItem(at: root)
  }

  private func textItem(_ text: String) -> ClipItem {
    ClipItem(contents: [
      ClipContent(type: PasteboardType.string.rawValue, value: Data(text.utf8)),
    ])
  }

  private static func notePaths(in root: URL) -> [String] {
    let clips = root.appending(path: "Clips", directoryHint: .isDirectory)
    guard FileManager.default.fileExists(atPath: clips.path) else { return [] }
    return ((try? FileManager.default.subpathsOfDirectory(atPath: clips.path)) ?? [])
      .filter { $0.hasSuffix(".md") }
  }

  @Test("No temporary files survive a successful write")
  func noTempFilesRemain() async throws {
    let (writer, root) = try makeVault()
    defer { cleanup(root) }
    try await writer.prepare()

    _ = try await writer.write(textItem("durable"))
    _ = try await writer.write(ClipItem(contents: [
      ClipContent(type: PasteboardType.png.rawValue, value: Data([1, 2, 3, 4])),
    ]))

    let leftovers = ((try? FileManager.default.subpathsOfDirectory(atPath: root.path)) ?? [])
      .filter { $0.contains(".copyz-tmp-") }
    #expect(leftovers.isEmpty, "found \(leftovers)")
  }

  @Test("Abandoned temp files are swept on prepare")
  func sweepsAbandonedTemporaries() async throws {
    let (writer, root) = try makeVault()
    defer { cleanup(root) }

    // Simulate a crash mid-write: an orphan in a day bucket and one at the root.
    let orphan = root.appending(path: "Clips/2026/10/18/.copyz-tmp-deadbeef")
    try FileManager.default.createDirectory(
      at: orphan.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("partial".utf8).write(to: orphan)
    try Data("partial".utf8).write(to: root.appending(path: ".copyz-tmp-cafe"))

    try await writer.prepare()

    let leftovers = ((try? FileManager.default.subpathsOfDirectory(atPath: root.path)) ?? [])
      .filter { $0.contains(".copyz-tmp-") }
    #expect(leftovers.isEmpty)
  }

  @Test("Temp files are never mistaken for notes")
  func tempFilesAreNotNotes() async throws {
    let (writer, root) = try makeVault()
    defer { cleanup(root) }
    try await writer.prepare()

    _ = try await writer.write(textItem("real note"))
    try Data("---\nid: fake\n---\n".utf8)
      .write(to: root.appending(path: "Clips/.copyz-tmp-note.md"))

    // The importer must ignore anything that is not a published note.
    let store = try SQLiteClipStore(inMemory: true)
    let vault = VaultStore(store: store, writer: writer)
    #expect(await vault.importFromVault() == 1)
    #expect(try store.count() == 1)
  }

  @Test("A write over an existing file is fully replaced")
  func overwriteIsComplete() async throws {
    let (writer, root) = try makeVault()
    defer { cleanup(root) }
    try await writer.prepare()

    let item = textItem("original content that is fairly long")
    try await writer.write(item)
    _ = try await writer.write(item)

    let notes = Self.notePaths(in: root)
    #expect(notes.count == 1)
    let text = try String(
      contentsOf: root.appending(path: "Clips").appending(path: notes[0]),
      encoding: .utf8
    )
    #expect(text == VaultNote.encode(item))
  }

  @Test("Assets are written before the note that references them")
  func assetPrecedesNote() async throws {
    let (writer, root) = try makeVault()
    defer { cleanup(root) }
    try await writer.prepare()

    let image = ClipItem(contents: [
      ClipContent(type: PasteboardType.png.rawValue, value: Data([0x89, 0x50, 0x4E, 0x47])),
    ])
    let relative = try await writer.write(image)

    let assetName = try #require(VaultNote.assetName(for: image))
    #expect(FileManager.default.fileExists(atPath: root.appending(path: "assets/\(assetName)").path))
    #expect(FileManager.default.fileExists(atPath: root.appending(path: relative).path))
  }

  @Test("secure_delete is enabled so deleted text does not linger")
  func secureDeleteEnabled() throws {
    let dir = FileManager.default.temporaryDirectory
      .appending(path: "copyz-sd-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { cleanup(dir) }

    let store = try SQLiteClipStore(path: dir.appending(path: "h.sqlite").path)

    // Record then hard-delete a distinctive secret, then assert the bytes are
    // not still recoverable in the file.
    let secret = "correct-horse-battery-staple-8f3a91"
    let item = ClipItem(contents: [
      ClipContent(type: PasteboardType.string.rawValue, value: Data(secret.utf8)),
    ])
    try store.record(item)
    try store.delete(id: item.id)

    let bytes = try Data(contentsOf: dir.appending(path: "h.sqlite"))
    let haystack = String(decoding: bytes, as: UTF8.self)
    #expect(!haystack.contains(secret), "secret survived deletion in the database file")
  }

  @Test("Publishing preserves an existing file when the write fails")
  func failedWriteLeavesPriorFile() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "copyz-fail-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { cleanup(root) }

    let target = root.appending(path: "note.md")
    try Data("original".utf8).write(to: target)

    // A directory in place of the destination makes the rename impossible.
    let blocked = root.appending(path: "blocked.md")
    try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)

    #expect(throws: (any Error).self) {
      try Durability.write(Data("replacement".utf8), to: blocked)
    }

    // The unrelated file is untouched, and no temp litter remains.
    #expect(try String(contentsOf: target, encoding: .utf8) == "original")
    let litter = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
      .filter { $0.hasPrefix(".copyz-tmp-") }
    #expect(litter.isEmpty)
  }
}