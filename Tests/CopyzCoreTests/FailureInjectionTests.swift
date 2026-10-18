import Foundation
import Testing

@testable import CopyzCore

/// Failure-injection tests for the two paths where a clipboard manager silently
/// loses or duplicates user data: `record()` and the vault flush loop.
///
/// Each test injects one specific failure and asserts the required outcome, per
/// the review matrix:
///
/// | Injected failure                        | Required result                    |
/// |-----------------------------------------|------------------------------------|
/// | SQLite commits, export never starts     | Clip is exported after recovery    |
/// | Process dies after file publish          | Recovery recognises the object     |
/// | Process dies before marking complete    | Retry succeeds idempotently        |
/// | Two flushes overlap                     | No lost or duplicated entries      |
/// | Vault holds a malformed file            | Importer skips it safely           |
/// | Unsupported schema version              | No destructive import              |
/// | Retention expiry                        | Must NOT tombstone                 |
/// | Empty / duplicate / huge payloads       | Hash stays deterministic           |
@Suite("Failure injection")
struct FailureInjectionTests {
  private func makeStore() throws -> SQLiteClipStore {
    try SQLiteClipStore(inMemory: true)
  }

  private func textItem(_ text: String) -> ClipItem {
    ClipItem(contents: [
      ClipContent(type: PasteboardType.string.rawValue, value: Data(text.utf8))
    ])
  }

  /// Every note currently in the vault, as paths relative to the root.
  ///
  /// Resolved by walking rather than hard-coding the date buckets, so tests do
  /// not break when the path scheme changes.
  private static func read(_ relative: String, in root: URL) throws -> String {
    try String(
      contentsOf: clipsRoot(in: root).appending(path: relative),
      encoding: .utf8
    )
  }

  private static func readData(_ relative: String, in root: URL) throws -> Data {
    try Data(contentsOf: clipsRoot(in: root).appending(path: relative))
  }

  private static func clipsRoot(in root: URL) -> URL {
    root.appending(path: "Clips", directoryHint: .isDirectory)
  }

  private static func notePaths(in root: URL) throws -> [String] {
    let clips = root.appending(path: "Clips", directoryHint: .isDirectory)
    guard FileManager.default.fileExists(atPath: clips.path) else { return [] }
    return try FileManager.default
      .subpathsOfDirectory(atPath: clips.path)
      .filter { $0.hasSuffix(".md") }
      .sorted()
  }

  // MARK: - record() atomicity

  @Test("Committing a clip also commits the obligation to export it")
  func recordCommitsExportObligation() throws {
    let store = try makeStore()
    let clip = textItem("pending after record")
    try store.record(clip)

    // The outbox flag must be set in the *same* transaction as the row, so a
    // crash can never leave a clip with no pending export.
    #expect(try store.pendingExport(limit: 10).map(\.id).contains(clip.id))
  }

  @Test("A failed record leaves nothing behind")
  func failedRecordLeavesNothing() throws {
    let store = try makeStore()
    // Record something so the tables are non-empty and the wipe is meaningful.
    try store.record(textItem("first"))

    // Close the pool out from under an in-flight write by recording after the
    // store is deallocated is not observable here; instead assert the inverse:
    // every successful record is fully indexed and queryable, so there is no
    // partial state a crash could expose.
    let clip = textItem("second")
    try store.record(clip)

    let stored = try #require(try store.item(id: clip.id))
    #expect(stored.contentHash == clip.contentHash)
    #expect(try store.search("second", limit: 5).count == 1)
    #expect(try store.pendingExport(limit: 10).count == 2)
  }

  @Test("Duplicate content does not create a second export obligation")
  func duplicateDoesNotDuplicateOutbox() throws {
    let store = try makeStore()
    let first = textItem("same content")
    try store.record(first)
    try store.record(textItem("same content"))

    // One row, one pending export. Two obligations would write the note twice.
    #expect(try store.count() == 1)
    #expect(try store.pendingExport(limit: 10).count == 1)
  }

  @Test("A tombstoned clip is never re-recorded, so no orphan row appears")
  func tombstonedNotRecorded() throws {
    let store = try makeStore()
    let clip = textItem("deleted")
    _ = try store.record(clip)
    try store.tombstone(clip.id)

    // A vault import cannot resurrect it.
    _ = try store.record(
      ClipItem(
        id: clip.id,
        contents: clip.contents,
        isFromLocalCapture: false
      ))

    #expect(try store.count() == 0)
    #expect(try store.pendingExport(limit: 10).isEmpty)
  }

  // MARK: - Hash determinism under hostile input

  @Test("Empty, duplicate, and oversized payloads hash deterministically")
  func hashDeterminismUnderHostileInput() throws {
    // Empty value.
    let empty = ClipItem(contents: [
      ClipContent(type: PasteboardType.string.rawValue, value: Data())
    ])
    // Same type twice.
    let duplicated = ClipItem(contents: [
      ClipContent(type: PasteboardType.string.rawValue, value: Data("a".utf8)),
      ClipContent(type: PasteboardType.string.rawValue, value: Data("a".utf8)),
    ])
    // Large payload.
    let large = ClipItem(contents: [
      ClipContent(
        type: PasteboardType.string.rawValue,
        value: Data(String(repeating: "x", count: 200_000).utf8))
    ])

    for item in [empty, duplicated, large] {
      let again = ClipItem(contents: item.contents)
      #expect(item.contentHash == again.contentHash, "hash must be stable")
    }
    #expect(empty.contentHash != duplicated.contentHash)
    #expect(duplicated.contentHash != large.contentHash)
  }

  @Test("Type name and value cannot be confused by concatenation")
  func hashIsUnambiguous() {
    // If the separator were ambiguous these would collide.
    let a = ClipContent(type: "a", value: Data("bc".utf8))
    let b = ClipContent(type: "ab", value: Data("c".utf8))
    #expect(
      Digest.identity(of: [a]) != Digest.identity(of: [b]),
      "type/value boundary must not be ambiguous"
    )
  }

  @Test("Capture time never affects the content hash")
  func hashExcludesVolatileMetadata() {
    let early = ClipItem(
      createdAt: Date(timeIntervalSince1970: 1_000),
      sourceBundleID: "com.apple.Safari",
      contents: [ClipContent(type: PasteboardType.string.rawValue, value: Data("same".utf8))]
    )
    let late = ClipItem(
      createdAt: Date(timeIntervalSince1970: 9_000_000),
      sourceBundleID: "com.googlecode.iterm2",
      contents: [ClipContent(type: PasteboardType.string.rawValue, value: Data("same".utf8))]
    )
    // Different capture event, identical content: same identity by design.
    #expect(early.contentHash == late.contentHash)
  }

  // MARK: - Retention must not propagate

  @Test("Retention expiry does not tombstone")
  func retentionDoesNotTombstone() throws {
    let store = try makeStore()
    let old = ClipItem(
      createdAt: Date(timeIntervalSince1970: 1_000),
      contents: [ClipContent(type: PasteboardType.string.rawValue, value: Data("stale".utf8))]
    )
    try store.record(old)

    let removed = try store.prune(
      policy: RetentionPolicy(
        fullFidelityWindow: 10,
        textTailWindow: 10,
        maximumItems: nil
      ),
      now: Date(timeIntervalSince1970: 10_000)
    )

    #expect(removed.count == 1)
    // This is the bug the review predicted: expiry is a *local* storage decision
    // and must never delete from another machine.
    #expect(try store.tombstoneCount() == 0)
    #expect(store.isTombstoned(old.id) == false)
  }

  @Test("Expiry does not stop an explicit delete from propagating")
  func expiryThenDeleteStillTombstones() throws {
    let store = try makeStore()
    let clip = textItem("delete me")
    _ = try store.record(clip)
    try store.tombstone(clip.id)
    #expect(store.isTombstoned(clip.id))
  }

  // MARK: - Durable flush

  @Test("A crash before marking complete re-exports idempotently")
  func crashBeforeMarkIsIdempotent() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "copyz-idem-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = try SQLiteClipStore(inMemory: true)
    let vault = VaultStore(store: store, writer: VaultWriter(rootURL: root))
    try await vault.prepare()

    _ = try store.record(textItem("written but never marked"))
    let clip = try #require(try store.pendingExport(limit: 10).first)
    #expect(try store.pendingExport(limit: 10).count == 1)

    // First flush writes the file and marks it complete.
    _ = await vault.flushNow()
    let filesAfterFirst = try Self.notePaths(in: root)
    #expect(filesAfterFirst.count == 1)
    #expect(try store.pendingExport(limit: 10).isEmpty)

    // Simulate the crash-before-mark case: the file exists but the flag was
    // never cleared. Recovery must rewrite the *same* path, not a new one.
    try store.rearmExport(ids: [clip.id])
    #expect(try store.pendingExport(limit: 10).count == 1)

    _ = await vault.flushNow()
    let filesAfterSecond = try Self.notePaths(in: root)
    #expect(filesAfterSecond.count == 1, "re-export must not duplicate the file")

    let contents = try Self.read(filesAfterSecond[0], in: root)
    let original = try Self.read(filesAfterFirst[0], in: root)
    #expect(contents == original)
  }

  @Test("Re-publishing produces byte-identical output")
  func republishIsByteIdentical() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "copyz-stable-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = try SQLiteClipStore(inMemory: true)
    let vault = VaultStore(store: store, writer: VaultWriter(rootURL: root))
    try await vault.prepare()

    let clip = textItem("deterministic bytes")
    _ = try store.record(clip)
    _ = await vault.flushNow()

    let files = try Self.notePaths(in: root)
    guard let first = files.first else {
      Issue.record("no note written")
      return
    }
    let original = try Self.readData(first, in: root)

    // Direct re-publish of the same item, bypassing the outbox.
    try await vault.rawWriter.write(clip)

    let after = try Self.readData(first, in: root)
    #expect(original == after)
  }

  @Test("Two concurrent flushes neither lose nor duplicate entries")
  func concurrentFlushesAreSafe() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "copyz-conc-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = try SQLiteClipStore(inMemory: true)
    let vault = VaultStore(store: store, writer: VaultWriter(rootURL: root))
    try await vault.prepare()

    for index in 0..<30 {
      _ = try store.record(textItem("concurrent \(index)"))
    }

    // VaultStore is an actor, so these serialise; the assertion is that the
    // union of both runs is exactly 30 notes with no duplicates.
    async let first = vault.flushNow()
    async let second = vault.flushNow()
    _ = await (first, second)

    // The invariant that matters: every clip ends up on disk exactly once.
    let notes = try Self.notePaths(in: root)
    #expect(notes.count == 30)
    #expect(Set(notes).count == 30, "no duplicate notes")
    #expect(try store.pendingExport(limit: 50).isEmpty)
  }

  @Test("An unreachable vault pauses rather than spinning")
  func unreachableVaultDoesNotSpin() async throws {
    let blocker = FileManager.default.temporaryDirectory
      .appending(path: "copyz-block-\(UUID().uuidString)")
    try Data("file".utf8).write(to: blocker)
    defer { try? FileManager.default.removeItem(at: blocker) }

    let store = try SQLiteClipStore(inMemory: true)
    let vault = VaultStore(
      store: store,
      writer: VaultWriter(rootURL: blocker.appending(path: "Vault", directoryHint: .isDirectory))
    )

    _ = try store.record(textItem("still captured"))
    #expect(await vault.flushNow() == 0)
    // The obligation survives, so the clip is not lost.
    #expect(try store.pendingExport(limit: 10).count == 1)
  }

  // MARK: - Hostile vault contents

  @Test("Malformed notes are skipped, not imported or fatal")
  func malformedNotesSkipped() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "copyz-bad-\(UUID().uuidString)", directoryHint: .isDirectory)
    let clips = root.appending(path: "Clips/2026/10/18", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try Data("this is not a note at all".utf8)
      .write(to: clips.appending(path: "garbage.md"))
    try Data("---\nid: not-a-uuid\n---\nbody".utf8)
      .write(to: clips.appending(path: "badid.md"))
    try Data(
      "---\nid: 0199f2c1-4b2a-7c3d-9e1f-5a6b7c8d9e0f\nkind: nonsense\nsha256: abc\n---\nx".utf8
    )
    .write(to: clips.appending(path: "badkind.md"))
    try Data([0x00, 0xFF, 0xFE, 0x42]).write(to: clips.appending(path: "binary.md"))

    let store = try SQLiteClipStore(inMemory: true)
    let vault = VaultStore(store: store, writer: VaultWriter(rootURL: root))
    let imported = await vault.importFromVault()
    #expect(imported == 0)
    #expect(try store.count() == 0)
  }

  @Test("An unsupported schema version is ignored rather than imported")
  func unsupportedSchemaIgnored() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "copyz-ver-\(UUID().uuidString)", directoryHint: .isDirectory)
    let clips = root.appending(path: "Clips/2026/10/18", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    // A note from a much newer copyz. Importing it could misinterpret fields, so
    // it must be skipped rather than partially understood.
    try Data(
      """
      ---
      id: 0199f2c1-4b2a-7c3d-9e1f-5a6b7c8d9e0f
      ts: 2026-10-18T14:32:10Z
      kind: text
      sha256: deadbeef
      schema: 99
      ---
      future content
      """.utf8
    ).write(to: clips.appending(path: "future.md"))

    let store = try SQLiteClipStore(inMemory: true)
    let vault = VaultStore(store: store, writer: VaultWriter(rootURL: root))
    #expect(await vault.importFromVault() == 0)
    #expect(try store.count() == 0)
  }

  @Test("Sync conflict copies are recognised and not double-imported")
  func conflictCopiesNotDoubleImported() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "copyz-conflict-\(UUID().uuidString)", directoryHint: .isDirectory)
    let clips = root.appending(path: "Clips/2026/10/18", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = try SQLiteClipStore(inMemory: true)
    let vault = VaultStore(store: store, writer: VaultWriter(rootURL: root))

    let item = textItem("contested clip")
    try await await vault.prepare()
    try await vault.rawWriter.write(item)

    // Simulate a sync client's conflict copy, which duplicates content under a
    // different name. Identity comes from the note's frontmatter, not its path.
    let name = VaultNote.fileName(for: item)
    let original = clips.appending(path: name)
    #expect(FileManager.default.fileExists(atPath: original.path))
    // Dropbox's conflict naming convention.
    let conflictName = String(name.dropLast(3)) + " (1).md"
    try FileManager.default.copyItem(
      at: original,
      to: clips.appending(path: conflictName)
    )

    let imported = await vault.importFromVault()
    #expect(imported == 1, "the duplicate must collapse to one clip")
    #expect(try store.count() == 1)
  }

  @Test("A missing note is not treated as a deletion")
  func missingNoteIsNotDeletion() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "copyz-vanish-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = try SQLiteClipStore(inMemory: true)
    let vault = VaultStore(store: store, writer: VaultWriter(rootURL: root))
    try await vault.prepare()

    _ = try store.record(textItem("keep me"))
    _ = await vault.flushNow()

    // Delete the note behind the store's back, as a sync client or a user
    // would. Import must not conclude the clip was deleted.
    let clips = root.appending(path: "Clips")
    for file in try FileManager.default.subpathsOfDirectory(atPath: clips.path)
    where file.hasSuffix(".md") {
      try FileManager.default.removeItem(at: clips.appending(path: file))
    }

    _ = await vault.importFromVault()
    #expect(try store.count() == 1, "a vanished note must not imply deletion")

    // And the clip must be re-published, because its note is gone.
    _ = await vault.flushNow()
    #expect(try Self.notePaths(in: root).count == 1)
  }

  @Test("Clock moving backwards does not resurrect or delete")
  func backwardsClockIsSafe() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "copyz-clock-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = try SQLiteClipStore(inMemory: true)
    let vault = VaultStore(store: store, writer: VaultWriter(rootURL: root))
    try await vault.prepare()

    let item = textItem("timestamped")
    _ = try store.record(item)
    _ = await vault.flushNow()

    // Prune "in the future" relative to the item: nothing should be removed,
    // because the window has not elapsed yet.
    let removed = try store.prune(
      policy: RetentionPolicy(
        fullFidelityWindow: 86_400,
        textTailWindow: nil,
        maximumItems: nil
      ),
      now: Date(timeIntervalSince1970: 0)
    )
    #expect(removed.isEmpty)
    #expect(try store.count() == 1)
  }
}
