import Foundation
import os

/// Durable file publication.
///
/// `Data.write(options: .atomic)` writes a temp file and renames, which stops a
/// reader seeing a half-written file — but it does **not** flush to the drive.
/// A crash or power loss can therefore lose a note that the app already
/// believes it has written, which is how a vault ends up with a flag saying
/// "exported" and no file on disk.
///
/// The sequence here is the standard three steps: write to a unique temp file in
/// the destination directory, flush the file, rename, then flush the directory
/// so the rename itself survives.
enum Durability {
  private static let log = Logger(subsystem: "com.buamod.sijil", category: "durability")

  enum Failure: LocalizedError {
    case couldNotCreate(URL)
    case writeFailed(URL, underlying: Error)
    case syncFailed(URL)

    public var errorDescription: String? {
      switch self {
      case .couldNotCreate(let url):
        "Could not create a temporary file beside \(url.lastPathComponent)."
      case .writeFailed(let url, let underlying):
        "Could not write \(url.lastPathComponent): \(underlying.localizedDescription)"
      case .syncFailed(let url):
        "Could not flush \(url.lastPathComponent) to disk."
      }
    }
  }

  static func write(_ data: Data, to url: URL) throws {
    let directory = url.deletingLastPathComponent()
    // The temp file must share a directory with the target, otherwise the
    // rename crosses a filesystem boundary and stops being atomic.
    let temporary = directory.appending(path: "\(tempPrefix)\(UUID().uuidString)")

    guard
      FileManager.default.createFile(
        atPath: temporary.path,
        contents: nil,
        attributes: [.posixPermissions: 0o600]
      )
    else {
      throw Failure.couldNotCreate(url)
    }

    do {
      try data.write(to: temporary)
      try sync(temporary)
      try replaceAtomically(temporary, with: url)
      // Without this the rename can be lost even though the bytes survived.
      try syncDirectory(directory)
    } catch let error as Failure {
      try? FileManager.default.removeItem(at: temporary)
      throw error
    } catch {
      try? FileManager.default.removeItem(at: temporary)
      throw Failure.writeFailed(url, underlying: error)
    }
  }

  /// Renames `source` over `destination`, which already exists.
  ///
  /// `FileManager.moveItem` refuses to clobber, so an idempotent re-publish
  /// would fail outright. `rename(2)` replaces atomically, which is what makes
  /// re-publishing the same clip safe.
  private static func replaceAtomically(_ source: URL, with destination: URL) throws {
    if rename(source.path, destination.path) == 0 { return }
    let code = errno

    // A directory cannot be replaced by a file, and neither can a file with a
    // directory. Surface that rather than silently deleting the user's data.
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(
      atPath: destination.path,
      isDirectory: &isDirectory
    )
    guard !exists || !isDirectory.boolValue else {
      throw Failure.writeFailed(
        destination,
        underlying: NSError(
          domain: NSPOSIXErrorDomain,
          code: Int(code),
          userInfo: [NSLocalizedDescriptionKey: "destination is a directory"]
        )
      )
    }

    throw Failure.writeFailed(
      destination,
      underlying: NSError(
        domain: NSPOSIXErrorDomain,
        code: Int(code),
        userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(code))]
      )
    )
  }

  /// Flushes a file's contents to stable storage.
  private static func sync(_ url: URL) throws {
    let descriptor = open(url.path, O_RDONLY)
    guard descriptor >= 0 else {
      throw Failure.syncFailed(url)
    }
    defer { close(descriptor) }
    // F_FULLFSYNC, not fsync: fsync only reaches the drive cache, which a power
    // loss can still discard.
    if fcntl(descriptor, F_FULLFSYNC) == -1 {
      // Some filesystems reject F_FULLFSYNC; fall back to fsync rather than
      // failing the write.
      _ = fsync(descriptor)
    }
  }

  private static func syncDirectory(_ url: URL) throws {
    let descriptor = open(url.path, O_RDONLY)
    guard descriptor >= 0 else { return }
    defer { close(descriptor) }
    _ = fsync(descriptor)
  }

  /// Removes abandoned temp files left by a crash mid-write.
  ///
  /// Called on launch: without it a hard crash accumulates `.sijil-tmp-*`
  /// files in every day bucket the app ever wrote to.
  static func sweepTemporaries(in root: URL, fileManager: FileManager = .default) {
    // Hidden files are *not* skipped here, unlike in the importer: the temp
    // files are hidden by design (dot prefix), so skipping them would skip
    // exactly what this sweep exists to remove.
    guard
      let enumerator = fileManager.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey]
      )
    else { return }

    var removed = 0
    for case let url as URL in enumerator
    where url.lastPathComponent.hasPrefix(tempPrefix) {
      try? fileManager.removeItem(at: url)
      removed += 1
    }
    if removed > 0 {
      log.info("swept \(removed) abandoned temporary files")
    }
  }

  /// Dot-prefixed so the importer's `skipsHiddenFiles` walk never sees one.
  static let tempPrefix = ".sijil-tmp-"
}
