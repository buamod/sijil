import CopyzCore
import SwiftUI

/// Applies a transform to a clip and puts the result back on the clipboard as
/// a fresh entry.
///
/// The transformed text is recorded as a *new* clip rather than replacing the
/// original: you almost always want to keep what you copied and paste the
/// converted form too.
@MainActor
@Observable
final class TransformModel {
  var item: ClipItem?
  var query = ""
  var result: String?
  var selectedTransform: Transform?
  /// Transforms that produced nothing for this input, so the UI can dim them
  /// instead of hiding them — the list stays stable as the user types.
  var unavailable: Set<String> = []

  private var evaluated: [Transform] = []

  var visible: [Transform] { evaluated }

  func load(_ item: ClipItem?) {
    guard self.item?.id != item?.id else { return }
    self.item = item
    result = nil
    selectedTransform = nil
    reevaluate()
  }

  /// Recomputes which transforms apply. Cheap enough to run on every keystroke
  /// for clipboard-sized text.
  func reevaluate() {
    guard let item else {
      evaluated = []
      unavailable = []
      return
    }
    // Prefer full text over the title-capped preview.
    let text = ClipPreview.text(for: item) ?? item.title

    let trimmed = query.trimmingCharacters(in: .whitespaces)
    let candidates =
      trimmed.isEmpty
      ? TransformCatalog.all
      : TransformCatalog.all.filter {
        $0.name.localizedCaseInsensitiveContains(trimmed)
          || $0.id.localizedCaseInsensitiveContains(trimmed)
      }

    evaluated = candidates
    unavailable = Set(candidates.compactMap { $0.run(text) == nil ? $0.id : nil })

    // Refresh the current result, since the input may have changed underneath.
    if let selectedTransform {
      result = selectedTransform.run(text)
    }
  }

  func run(_ transform: Transform) {
    guard let item else { return }
    selectedTransform = transform
    result = transform.run(ClipPreview.text(for: item) ?? item.title)
  }

  var sourceText: String {
    guard let item else { return "" }
    return ClipPreview.text(for: item) ?? item.title
  }
}

struct TransformSheet: View {
  @Bindable var model: TransformModel
  let onApply: (String) -> Void
  let onDismiss: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      HStack(spacing: 0) {
        transformList
        Divider()
        resultPane
      }
      Divider()
      footer
    }
    .frame(width: 720, height: 460)
    .background { GlassBackground() }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 6) {
      TextField("Filter transforms", text: $model.query)
        .textFieldStyle(.plain)
        .onChange(of: model.query) { _, _ in model.reevaluate() }
      Text(model.item.map { "Transforming: \($0.kind.displayName)" } ?? "Nothing selected")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
  }

  private var transformList: some View {
    List(model.visible, selection: $model.selectedTransform) { transform in
      VStack(alignment: .leading, spacing: 1) {
        Text(transform.name)
          .strikethrough(false)
        Text(transform.detail)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      .opacity(model.unavailable.contains(transform.id) ? 0.4 : 1)
      .tag(transform)
      .contextMenu {
        Button("Copy Result") {
          if let result = model.result { copy(result) }
        }
      }
    }
    .frame(width: 260)
  }

  private var resultPane: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Result")
        .font(.caption)
        .foregroundStyle(.secondary)
      ScrollView {
        Text(model.result ?? "Choose a transform")
          .font(.system(.body, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var footer: some View {
    HStack(spacing: 10) {
      Button("Close") { onDismiss() }
        .keyboardShortcut(.cancelAction)
      Spacer()
      Button("Copy") {
        if let result = model.result { copy(result) }
      }
      Button("Copy and Paste") {
        if let result = model.result { onApply(result) }
      }
      .keyboardShortcut(.defaultAction)
      .disabled(model.result == nil)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
  }

  private func copy(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
  }
}
