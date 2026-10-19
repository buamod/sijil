import Foundation
import Observation
import SijilCore

/// Small observable cache the SwiftUI views read from.
///
/// `ClipboardService` is `@MainActor` but `await`-bound, which SwiftUI cannot
/// express in a view body. This mirrors the values the panel needs so the panel
/// can be built synchronously from a snapshot.
@MainActor
@Observable
final class TaskCache {
  static let shared = TaskCache()

  var collections: [Collection] = []

  private init() {}

  func update(collections: [Collection]) {
    self.collections = collections
  }
}
