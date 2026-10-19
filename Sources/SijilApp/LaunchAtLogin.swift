import Foundation
import ServiceManagement

/// Abstraction over the system's login-item registry.
///
/// `SMAppService` cannot be exercised from a test process — it needs a real
/// signed bundle — so the policy that decides *whether* registration should
/// succeed lives here and the actual system call is injected.
public protocol LoginItemRegistering: Sendable {
  var isRegistered: Bool { get }
  func register() throws
  func unregister() throws
}

public enum LoginItemError: LocalizedError {
  case notBundled

  public var errorDescription: String? {
    switch self {
    case .notBundled:
      "Launch at login only works from the installed sijil app, not from a "
        + "development build."
    }
  }
}

/// The real registry, backed by `SMAppService`.
///
/// `SMAppService` is not marked `Sendable` but is safe to use from any thread
/// for registration calls, and sijil only touches it from the main actor.
@available(macOS 13, *)
public final class SystemLoginItem: LoginItemRegistering, @unchecked Sendable {
  private let service: SMAppService

  public init() {
    self.service = SMAppService.mainApp
  }

  public var isRegistered: Bool { service.status == .enabled }

  public func register() throws {
    try service.register()
  }

  public func unregister() throws {
    try service.unregister()
  }
}

/// Login-item handling that reports why a request could not be honoured.
public enum LaunchAtLogin {
  /// The backing registry. Overridden in tests.
  nonisolated(unsafe) static var backend: any LoginItemRegistering = Default()

  public static var isRegistered: Bool {
    backend.isRegistered
  }

  public static func set(_ enabled: Bool) throws {
    if enabled {
      try backend.register()
    } else {
      try backend.unregister()
    }
  }

  /// A backend that refuses every request, standing in for an unbundled run.
  private struct Default: LoginItemRegistering {
    var isRegistered: Bool {
      Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    func register() throws { try guardBundled(); try SystemLoginItem().register() }
    func unregister() throws { try guardBundled(); try SystemLoginItem().unregister() }

    private func guardBundled() throws {
      if Bundle.main.bundleURL.pathExtension != "app" { throw LoginItemError.notBundled }
    }
  }

  /// Restores the real backend. Used by tests to avoid leaking fakes.
  public static func reset() {
    backend = Default()
  }
}
