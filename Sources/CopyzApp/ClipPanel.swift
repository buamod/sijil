import AppKit
import CopyzCore
import CopyzPaste
import SwiftUI

/// The floating history window.
///
/// `NSPanel` rather than a SwiftUI `Window`/`WindowGroup` because
/// `.nonactivatingPanel` has no SwiftUI equivalent, and it is what stops a
/// click inside the panel from activating us — which in turn leaves the target
/// app's menu tracking intact. `canBecomeKey` is true so the search field can
/// take input; `canBecomeMain` stays false so we never become the active app.
@MainActor
final class ClipPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

struct ClipListView: View {
  @Bindable var model: PanelModel
  var collections: [Collection] = []
  let onCopy: (ClipItem) -> Void
  let onPaste: (ClipItem) -> Void
  let onTogglePin: (ClipItem) -> Void
  let onDelete: (ClipItem) -> Void
  let onSearch: (String) -> Void
  let onDismiss: () -> Void
  let onTransform: (ClipItem) -> Void
  let onPreview: (ClipItem) -> Void
  let onFile: (ClipItem, UUID?) -> Void
  let onToggleLock: (ClipItem) -> Void
  /// Deletes everything except locked items.
  let onClearHistory: () -> Void
  /// Why the last copy was skipped, if it was.
  var rejection: CaptureRules.Rejection?

  var body: some View {
    VStack(spacing: 0) {
      searchField
      Divider()
      list
      Divider()
      footer
    }
    .frame(width: 420, height: 460)
    .background { GlassBackground() }
  }

  private var searchField: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)
      TextField("Search clipboard", text: $model.query)
        .textFieldStyle(.plain)
        .onSubmit { if let item = model.selectedItem { onCopy(item) } }
        .onChange(of: model.query) { _, newValue in
          onSearch(newValue)
        }
      if model.isQuickMode {
        Text("quick")
          .font(.caption2)
          .padding(.horizontal, 5)
          .padding(.vertical, 1)
          .background(.quaternary, in: Capsule())
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
  }

  private var list: some View {
    ScrollViewReader { proxy in
      List(selection: selectionBinding) {
        ForEach(model.items) { item in
          ClipRow(item: item)
            .tag(item.id)
            .contextMenu { contextMenu(for: item) }
            .onTapGesture(count: 2) { onPreview(item) }
        }
      }
      .listStyle(.plain)
      .onChange(of: model.selection) { _, newValue in
        guard let newValue else { return }
        withAnimation { proxy.scrollTo(newValue, anchor: .center) }
      }
    }
  }

  /// Extracted because a large view expression inside `List` can trip the
  /// SwiftUI type-checker's expression-size limit.
  private var selectionBinding: Binding<UUID?> {
    Binding(
      get: { model.selection },
      set: { model.selection = $0 }
    )
  }

  @ViewBuilder
  private func contextMenu(for item: ClipItem) -> some View {
    Button("Copy") { onCopy(item) }
    Button("Paste") { onPaste(item) }
    Button("Transform…") { onTransform(item) }
    Button("Preview") { onPreview(item) }
    Divider()
    Button(item.pinned ? "Unpin" : "Pin") { onTogglePin(item) }
    Button(item.locked ? "Unlock" : "Lock (survives Clear History)") {
      onToggleLock(item)
    }
    Menu("Add to Collection") {
      Button("None") { onFile(item, nil) }
      if !collections.isEmpty { Divider() }
      ForEach(collections) { collection in
        Button(collection.name) { onFile(item, collection.id) }
      }
    }
    Divider()
    Button("Delete", role: .destructive) { onDelete(item) }
  }

  private var footer: some View {
    HStack(spacing: 12) {
      Text("\(model.items.count) items")
        .font(.caption)
        .foregroundStyle(.secondary)
      if model.items.count > 0 {
        // Destructive, and permanent, so it confirms. It is also a *delete*, not
        // a prune: the tombstones it writes are what stop the other machines in
        // the vault from re-importing everything just cleared.
        Button("Clear History…") { confirmingClear = true }
          .font(.caption)
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
      }
      Spacer()
      if let rejection = rejectionText {
        Text(rejection)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Button("Close") { onDismiss() }
        .keyboardShortcut(.cancelAction)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .confirmationDialog(
      "Delete all clipboard history?",
      isPresented: $confirmingClear,
      titleVisibility: .visible
    ) {
      Button("Clear History", role: .destructive) { onClearHistory() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "Locked items are kept. This cannot be undone, and it removes the items "
          + "from every machine syncing this vault."
      )
    }
  }

  @State private var confirmingClear = false

  /// Explains why the most recent copy was not recorded, so a skipped clip is
  /// answerable rather than mysterious.
  private var rejectionText: String? {
    guard let reason = rejection else { return nil }
    return "Not recorded: \(reason)"
  }
}

struct ClipRow: View {
  let item: ClipItem

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: iconName)
        .foregroundStyle(.secondary)
        .frame(width: 16)
      VStack(alignment: .leading, spacing: 2) {
        Text(item.title.isEmpty ? "(\(item.kind.displayName))" : item.title)
          .lineLimit(2)
          .font(.callout)
        HStack(spacing: 6) {
          Text(item.kind.displayName)
          if let app = item.sourceAppName, !app.isEmpty {
            Text("·")
            Text(app)
          }
          Text("·")
          Text(item.createdAt, format: .relative(presentation: .numeric))
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
      VStack(alignment: .trailing, spacing: 2) {
        if item.locked {
          // Lock outranks pin: it is the stronger promise.
          Image(systemName: "lock.fill")
            .font(.caption2)
            .foregroundStyle(.tint)
        }
        if item.pinned {
          Image(systemName: "pin.fill")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
    }
    .padding(.vertical, 2)
  }

  private var iconName: String {
    switch item.kind {
    case .text: "text.alignleft"
    case .richText: "textformat"
    case .html: "chevron.left.forwardslash.chevron.right"
    case .link: "link"
    case .color: "paintpalette"
    case .emoji: "face.smiling"
    case .image: "photo"
    case .file: "doc"
    case .files: "folder"
    }
  }
}

/// macOS 26 Liquid Glass where available, `NSVisualEffectView` otherwise.
///
/// `NSGlassEffectView` is public API on macOS 26, but the ~20 "materials"
/// variants are SPI, so only the four documented properties are used. Glass is
/// expensive on the GPU, so it goes on the panel chrome only — never per row.
struct GlassBackground: View {
  var body: some View {
    if #available(macOS 26.0, *) {
      Color.clear.glassEffect(.regular, in: .rect(cornerRadius: 12))
    } else {
      VisualEffectFallback()
    }
  }
}

struct VisualEffectFallback: NSViewRepresentable {
  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.blendingMode = .withinWindow
    view.state = .active
    view.material = .popover
    return view
  }

  func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}