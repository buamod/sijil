import CommonCrypto
import Foundation

/// MD5, isolated to one file.
///
/// MD5 is cryptographically broken and Apple's headers mark it deprecated, but
/// it remains the algorithm people reach for when eyeballing whether two
/// pastes are identical. Confining the call here keeps that warning out of the
/// rest of the build.
///
/// SHA-256 is the right choice for anything security-relevant and sits next to
/// this in the transform catalogue.
enum MD5Digest {
  static func hex(of input: String) -> String {
    // A raw allocation rather than a Swift array: CC_MD5 takes an in/out
    // pointer, and passing the array itself would trip Swift exclusivity.
    let digest = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(CC_MD5_DIGEST_LENGTH))
    defer { digest.deallocate() }
    digest.initialize(repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))

    _ = Data(input.utf8).withUnsafeBytes { source in
      // Deprecated in Apple's headers and cryptographically broken; this is a
      // non-security fingerprint, and the reason is documented above.
      CC_MD5(source.baseAddress, CC_LONG(source.count), digest)
    }

    var out = ""
    out.reserveCapacity(Int(CC_MD5_DIGEST_LENGTH) * 2)
    for index in 0..<Int(CC_MD5_DIGEST_LENGTH) {
      out += String(format: "%02x", digest[index])
    }
    return out
  }
}