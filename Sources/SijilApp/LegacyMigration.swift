import Foundation

/// One-time migration from the previous application folder.
///
/// The app was renamed, which changes its Application Support directory from
/// `copyz` to `sijil`. Renaming a folder does not move the folder: a user who
/// upgrades would come back to an empty history and an empty vault, with no
/// error and no way to tell that anything had been lost.
///
/// So this looks for the old location and copies it across — never silently, and
/// never destructively. The old folder is left exactly where it was, so if
/// anything goes wrong the data is still there.
public enum LegacyMigration {
  /// The directory name used before the rename.
  public static let legacyFolderName = "copyz"

  /// Where the app's data lives.
  ///
  /// Not `~/Documents` or anywhere TCC-protected: the vault has to be readable
  /// without a permission prompt.
  public static func applicationSupportRoot(fileManager: FileManager = .default) -> URL {
    let base =
      (try? fileManager.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
    return base.appending(path: "sijil", directoryHint: .isDirectory)
  }

  /// What happened.
  public enum Outcome: Equatable {
    /// Nothing to do: either no legacy data, or it has already been migrated.
    case none
    /// Copied, and says how many items moved.
    case migrated(fileCount: Int)
    /// Legacy data exists but could not be read or written.
    case failed(String)
  }

  /// Copies legacy data across if it exists and the new location is empty.
  ///
  /// Deliberately refuses to merge. If the new location already has a vault,
  /// copying into it would produce a mix of two histories with no way to tell
  /// which is which — worse than either one on its own. The user can merge by
  /// hand, or delete one folder.
  ///
  /// The roots are injectable because the default reads the *real*
  /// Application Support directory. Without injection, a test of this would
  /// quietly copy the user's actual history — which is exactly what happened the
  /// first time this was written.
  @discardableResult
  public static func migrateIfNeeded(
    legacy: URL? = nil,
    current: URL? = nil,
    fileManager: FileManager = .default
  ) -> Outcome {
    let legacy = legacy ?? legacyRoot(fileManager: fileManager)
    let current = current ?? applicationSupportRoot(fileManager: fileManager)

    // Nothing to migrate from.
    guard fileManager.fileExists(atPath: legacy.path) else { return .none }

    // Refuse to merge into an existing history rather than interleave two.
    if fileManager.fileExists(atPath: current.path),
      let existing = try? fileManager.contentsOfDirectory(atPath: current.path),
      !existing.isEmpty
    {
      return .none
    }

    do {
      try fileManager.createDirectory(at: current, withIntermediateDirectories: true)
      for name in try fileManager.contentsOfDirectory(atPath: legacy.path) {
        let source = legacy.appending(path: name)
        let destination = current.appending(path: name)
        guard !fileManager.fileExists(atPath: destination.path) else { continue }
        try fileManager.copyItem(at: source, to: destination)
      }
      return .migrated(fileCount: countNotes(in: current, fileManager: fileManager))
    } catch {
      // The legacy folder is untouched, so this is recoverable by hand.
      return .failed(error.localizedDescription)
    }
  }

  private static func legacyRoot(fileManager: FileManager) -> URL {
    let base =
      (try? fileManager.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: false
      )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
    return base.appending(path: legacyFolderName, directoryHint: .isDirectory)
  }

  /// Vault notes present, used only for the message shown to the user.
  private static func countNotes(in root: URL, fileManager: FileManager) -> Int {
    let clips = root.appending(path: "Vault", directoryHint: .isDirectory)
      .appending(path: "Clips", directoryHint: .isDirectory)
    guard fileManager.fileExists(atPath: clips.path) else { return 0 }
    let count =
      (try? fileManager.subpathsOfDirectory(atPath: clips.path))?
      .filter { $0.hasSuffix(".md") }.count ?? 0
    return count
  }

  /// Message shown once, after a successful migration.
  public static func notice(for outcome: Outcome) -> String? {
    switch outcome {
    case .none:
      return nil
    case .migrated(let fileCount):
      return fileCount > 0
        ? "Moved \(fileCount) clipboard \(fileCount == 1 ? "item" : "items") from the "
          + "previous sijil folder. Your old folder was left untouched."
        : "Moved your settings and history from the previous sijil folder. "
          + "Your old folder was left untouched."
    case .failed(let reason):
      return "Could not move your history from the previous sijil folder: \(reason). "
        + "Nothing was deleted — the old folder is still there."
    }
  }
}
