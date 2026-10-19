import CryptoKit
import Foundation

/// MD5, isolated to one file.
///
/// MD5 is cryptographically broken. Apple's headers mark `CC_MD5` deprecated,
/// which is correct, but the transform catalogue legitimately offers an MD5
/// fingerprint because that is the algorithm people reach for when eyeballing
/// whether two pastes are identical.
///
/// Uses `CryptoKit.Insecure.MD5` rather than `CC_MD5`. That is Apple's own
/// non-security hash, and unlike the C function it carries no deprecation
/// warning — the name says "insecure" at every call site instead of a warning
/// that gets suppressed once and then forgotten.
///
/// SHA-256 is the right choice for anything security-relevant and sits next to
/// this in the transform catalogue.
enum MD5Digest {
  static func hex(of input: String) -> String {
    Insecure.MD5.hash(data: Data(input.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }
}
