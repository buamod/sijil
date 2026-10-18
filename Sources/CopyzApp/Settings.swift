import CopyzCore
import Foundation
import Observation

/// User-facing preferences.
///
/// Kept deliberately small. Anything that changes *whether* a clip is recorded
/// lives in `CaptureRules`; this only holds what the user can reasonably be
/// expected to tune.
@MainActor
@Observable
public final class Settings {
  public var rules: CaptureRules {
    didSet { persist(rules, forKey: Keys.rules) }
  }

  public var retention: RetentionPolicy {
    didSet { persist(retention, forKey: Keys.retention) }
  }

  public var pollInterval: TimeInterval {
    didSet { defaults.set(pollInterval, forKey: Keys.pollInterval) }
  }

  public var vaultRootPath: String? {
    didSet { defaults.set(vaultRootPath, forKey: Keys.vaultRoot) }
  }

  public var launchAtLogin: Bool {
    didSet { defaults.set(launchAtLogin, forKey: Keys.launchAtLogin) }
  }

  private let defaults: UserDefaults

  private enum Keys {
    static let rules = "captureRules"
    static let retention = "retentionPolicy"
    static let pollInterval = "pollInterval"
    static let vaultRoot = "vaultRootPath"
    static let launchAtLogin = "launchAtLogin"
  }

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults

    let decodedRules = Self.read(CaptureRules.self, from: defaults, key: Keys.rules)
      ?? CaptureRules()
    // A previously-saved rule set must not resurrect capture as paused.
    self.rules = decodedRules.isCapturing ? decodedRules : CaptureRules()
    self.retention = Self.read(RetentionPolicy.self, from: defaults, key: Keys.retention)
      ?? RetentionPolicy()
    self.pollInterval = defaults.object(forKey: Keys.pollInterval) as? TimeInterval ?? 0.4
    self.vaultRootPath = defaults.string(forKey: Keys.vaultRoot)
    self.launchAtLogin = defaults.bool(forKey: Keys.launchAtLogin)
  }

  // `UserDefaults` has no built-in Codable bridge.
  private func persist<T: Encodable>(_ value: T, forKey key: String) {
    guard let data = try? JSONEncoder().encode(value) else { return }
    defaults.set(data, forKey: key)
  }

  private static func read<T: Decodable>(
    _ type: T.Type,
    from defaults: UserDefaults,
    key: String
  ) -> T? {
    guard let data = defaults.data(forKey: key) else { return nil }
    return try? JSONDecoder().decode(type, from: data)
  }

  /// Sensible default vault: a plain folder in Application Support, which needs
  /// no TCC grant. Deliberately *not* `~/Documents`, which would trigger a
  /// Files-and-Folders prompt for no benefit.
  public var defaultVaultURL: URL {
    let base = (try? FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
    return base.appending(path: "copyz/Vault", directoryHint: .isDirectory)
  }

  public var vaultURL: URL {
    if let vaultRootPath, !vaultRootPath.isEmpty {
      return URL(fileURLWithPath: vaultRootPath, isDirectory: true)
    }
    return defaultVaultURL
  }
}