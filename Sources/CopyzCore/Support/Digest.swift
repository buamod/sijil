import CryptoKit
import Foundation

/// Content-addressing helpers. Clip identity is derived from content so that
/// the same copy observed twice — or synced from another machine — collapses to
/// one row without a round trip to a server.
enum Digest {
  /// Hash of a single blob.
  static func hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  /// Order-independent identity for a set of typed blobs.
  ///
  /// Sorting by (type, per-blob hash) before combining means a copy that the
  /// source app advertises in a different type order still hashes identically.
  static func identity(of contents: some Sequence<ClipContent>) -> String {
    let parts = contents
      .map { "\($0.type):\(hex($0.value))" }
      .sorted()
    var hasher = SHA256()
    for part in parts {
      hasher.update(data: Data(part.utf8))
      hasher.update(data: Data([0x1F])) // unit separator, so parts cannot run together
    }
    return hex(Data(hasher.finalize()))
  }
}