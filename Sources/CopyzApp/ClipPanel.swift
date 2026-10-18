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
  let onCreateCollection: () -> Void
  let onRenameCollection: (UUID) -> Void
  let onDeleteCollection: (UUID) -> Void
  /// Why the last copy was skipped, if it was.
  var rejection: CaptureRules.Rejection?

  var body: some View {
    HStack(spacing: 0) {
      sidebar
      Divider()
      VStack(spacing: 0) {
        searchField
        Divider()
        list
        Divider()
        footer
      }
    }
    .frame(width: sidebarVisible ? 540 : 420, height: 460)
    .background { GlassBackground() }
  }

  /// Which buckets exist, plus a New Collection entry.
  private var sidebar: some View {
    List(selection: scopeBinding) {
      Section {
        Label("All", systemImage: "tray.full")
          .tag(PanelModel.Scope.all)
      }

      if !model.scopes.filter({ $0.0 == .pinned || $0.0 == .locked }).isEmpty {
        Section {
          ForEach(model.scopes.filter { $0.0 == .pinned || $0.0 == .locked },
                  id: \.0) { entry in
            Label(entry.1, systemImage: entry.0 == .pinned ? "pin.fill" : "lock.fill")
              .tag(entry.0)
          }
        }
      }

      Section("Collections") {
        ForEach(model.scopes.filter { if case .collection = $0.0 { true } else { false } },
                id: \.0) { entry in
          Label(entry.1, systemImage: "folder")
            .tag(entry.0)
            .contextMenu {
              Button("Rename…") {
                if case .collection(let id) = entry.0 { onRenameCollection(id) }
              }
              Button("Delete", role: .destructive) {
                if case .collection(let id) = entry.0 { onDeleteCollection(id) }
              }
            }
        }
        Button {
          onCreateCollection()
        } label: {
          Label("New Collection…", systemImage: "plus")
        }
        .buttonStyle(.plain)
      }
    }
    .listStyle(.sidebar)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      Button {
        sidebarVisible = false
      } label: {
        Label("Hide Collections", systemImage: "sidebar.left")
          .font(.caption)
      }
      .buttonStyle(.plain)
      .padding(6)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  @State private var sidebarVisible = true

  private var scopeBinding: Binding<PanelModel.Scope> {
    Binding(
      get: { model.scope },
      set: { model.selectScope($0) }
    )
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
        ForEach(model.visibleItems) { item in
          ClipRow(item: item, timestamp: model.timestamp(for: item))
            .tag(item.id)
            .contextMenu { contextMenu(for: item) }
            .onTapGesture(count: 2) { onPreview(item) }
        }
      }
      .listStyle(.plain)
      .onChange(of: model.selection) { _, newValue in
        guard let newValue else { return }
        // Only the keyboard gets the animation. Animating a click-driven scroll
        // is what made clicking feel sluggish: the row highlighted at once but
        // the list was still easing toward the new position afterwards.
        if model.selectionMovedByKeyboard {
          withAnimation { proxy.scrollTo(newValue, anchor: .center) }
        } else {
          // `anchor: nil` scrolls only as far as needed to reveal the row, which
          // is what a click should do — centring a clicked row throws away the
          // user's place in the list.
          proxy.scrollTo(newValue, anchor: nil)
        }
      }
    }
  }

  /// Extracted because a large view expression inside `List` can trip the
  /// SwiftUI type-checker's expression-size limit.
  private var selectionBinding: Binding<UUID?> {
    Binding(
      get: { model.selection },
      set: { value in
        // Routed through `select` so the view can tell a click from a keypress
        // and decide whether to animate.
        if let value { model.select(value) } else { model.selection = nil }
      }
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
      Text("\(model.visibleItems.count) of \(model.items.count)")
        .font(.caption)
        .foregroundStyle(.secondary)
      if !model.visibleItems.isEmpty {
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
  /// Pre-rendered, because a relative date style per row schedules its own
  /// refresh and a list of them re-renders on a timer.
  let timestamp: String

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
          Text(timestamp)
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