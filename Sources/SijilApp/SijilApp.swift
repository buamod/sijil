import AppKit
import Carbon.HIToolbox
import SijilCore
import SijilPaste
import SwiftUI

@main
struct SijilApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

  var body: some Scene {
    // Menu-bar-only: no Dock icon, no main window. `MenuBarExtra` supplies the
    // status item, so the delegate's hand-rolled `NSStatusItem` is not used.
    MenuBarExtra("sijil", systemImage: "doc.on.clipboard") {
      MenuBarContent(delegate: delegate)
    }

    // This scene has to exist for `showSettingsWindow:` to have a receiver.
    // Without it the menu bar's "Settings…" sends an action nobody implements and
    // silently does nothing — which is exactly what it was doing.
    SwiftUI.Settings {
      SettingsScene(delegate: delegate)
    }
  }
}

struct MenuBarContent: View {
  @Bindable var delegate: AppDelegate

  var body: some View {
    Text("\(delegate.itemCount) items")
    Divider()
    Button("Open Clipboard (\(AppDelegate.defaultHotKey.displayString))") {
      delegate.togglePanel()
    }
    Button("Ignore Next Copy") { delegate.skipNextCopy() }
    Divider()
    Button("Flush to Vault Now") { delegate.flushVault() }
    Button("Rebuild Index From Vault") { delegate.rebuildVault() }
    Divider()
    Button("Settings…") { delegate.openSettings() }
    Divider()
    Button("Quit sijil") { NSApp.terminate(nil) }
  }
}

@MainActor
@Observable
final class AppDelegate: NSObject, NSApplicationDelegate {
  let settings = Settings()
  private var service: ClipboardService?
  private var panel: ClipPanel?
  private let panelModel = PanelModel()
  private let hotKey = GlobalHotKey()
  private let keyMonitor = PanelKeyMonitor()

  // MARK: - Menu bar bridging

  /// Mirrors the service's item count so the SwiftUI menu can read it.
  var itemCount: Int { service?.items.count ?? 0 }

  func togglePanel() { togglePanelAction() }
  /// The running service, or a placeholder if construction failed.
  ///
  /// Exposed so the `Settings` scene can put it in the environment. `PrivacySettings`
  /// reads `lastRejection` from it, and a Settings scene is outside the main view
  /// tree, so nothing else would supply one.
  var clipboardService: ClipboardService {
    service ?? ClipboardService.unavailable(settings: settings)
  }

  /// Moves data out of the folder used before the rename, once.
  ///
  /// Renaming the app renamed its Application Support directory too, which would
  /// otherwise present as an empty history and an empty vault with no error. The
  /// old folder is never deleted, so this is always recoverable.
  private func checkForLegacyMigration() {
    let notice = LegacyMigration.notice(for: LegacyMigration.migrateIfNeeded())
    guard let notice else { return }
    presentError(LegacyMigrationNotice(notice))
  }

  /// Warns when a rebuild has silently revoked the Accessibility grant.
  ///
  /// Ad-hoc signing identifies the app by CDHash, so a new build looks like a
  /// different app to macOS. Nothing else tells the user why pasting stopped
  /// working, and "re-grant Accessibility" is not an obvious next step when you
  /// were only trying to pick up a fix.
  private func checkForSignatureChange() {
    let change = SignatureIdentity.recordLaunch()
    guard let explanation = SignatureIdentity.explanation(for: change) else { return }
    presentError(SignatureChangedError(explanation))
  }

  func skipNextCopy() { service?.skipNextCopy() }
  func flushVault() { Task { await service?.flushVault() } }
  func rebuildVault() { Task { await service?.rebuildFromVault() } }

  func openSettings() {
    NSApp.activate()
    // An `.accessory` app has no menu bar of its own, so ⌘, has no target either.
    // The explicit action send is the only route, and its return value is the
    // only signal that the `Settings` scene is actually present.
    let sent = NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    if !sent {
      presentError(SettingsUnavailableError())
    }
  }

  static let defaultHotKey = GlobalHotKey.Binding(
    keyCode: UInt32(kVK_ANSI_V),
    modifiers: UInt32(cmdKey | shiftKey),
    displayString: "⇧⌘V"
  )

  func applicationDidFinishLaunching(_ notification: Notification) {
    // `.accessory` keeps us out of the Dock and the app switcher.
    NSApp.setActivationPolicy(.accessory)

    do {
      let service = try ClipboardService(settings: settings)
      self.service = service
      Task { await service.start() }
    } catch {
      presentFatal(error)
      return
    }

    installHotKey()
    checkPasteboardAccess()
    checkForSignatureChange()

    // `sijil --settings` opens preferences directly. A menu-bar app has no
    // window to fall back on, so a broken or hidden menu bar item otherwise
    // leaves no route to the settings at all.
    if CommandLine.arguments.contains("--settings") {
      DispatchQueue.main.async { [weak self] in self?.openSettings() }
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    hotKey.unregister()
    keyMonitor.stop()
    Task {
      // Flush the vault before exiting so nothing pending is lost. The monitor
      // is already stopped, so no new work can arrive during the flush.
      await service?.stop()
      NSApp.terminate(nil)
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // Menu-bar app: closing a panel must not quit.
    false
  }

  // MARK: - Hotkey

  private func installHotKey() {
    do {
      try hotKey.register(binding: Self.defaultHotKey) { [weak self] in
        self?.hotKeyPressed()
      } onRelease: { [weak self] in
        self?.hotKeyReleased()
      }
    } catch {
      // A collision is expected and not fatal: fall back to the menu bar item.
      presentError(error)
    }
  }

  private func hotKeyPressed() {
    // Capture the paste target *now*: once the panel opens we are frontmost,
    // and reading `frontmostApplication` at paste time would hand us ourselves.
    service?.notePasteTarget(NSWorkspace.shared.frontmostApplication)
    panelModel.isQuickMode = true
    showPanel()
  }

  private func hotKeyReleased() {
    guard panelModel.isQuickMode else { return }
    // Quick Mode: holding the shortcut shows the panel, arrows move the
    // selection, and letting go pastes whatever is highlighted.
    panelModel.isQuickMode = false
    if let item = panelModel.selectedItem {
      service?.paste(item)
      hidePanel()
    }
  }

  /// Panel-local key handling. A local monitor needs no Accessibility grant,
  /// so this works before the user has granted anything.
  private func startKeyMonitor() {
    keyMonitor.start { [weak self] action in
      guard let self else { return }
      handle(action)
    }
  }

  private func handle(_ action: PanelKeyMonitor.Action) {
    switch action {
    case .moveSelection(let offset):
      panelModel.moveSelection(by: offset)

    case .copySelection, .pasteSelection:
      guard let item = panelModel.selectedItem else { return }
      if action == .pasteSelection {
        service?.paste(item)
      } else {
        service?.copy(item)
      }
      hidePanel()

    case .copySelectionPlain, .pasteSelectionPlain:
      guard let item = panelModel.selectedItem else { return }
      if action == .pasteSelectionPlain {
        service?.paste(item, plainTextOnly: true)
      } else {
        service?.copy(item, plainTextOnly: true)
      }
      hidePanel()

    case .togglePinSelection:
      guard let item = panelModel.selectedItem else { return }
      service?.togglePin(item)
      if let service { panelModel.replaceItems(service.items) }

    case .deleteSelection:
      guard let item = panelModel.selectedItem else { return }
      service?.delete(item)
      panelModel.removeItem(item.id)

    case .dismiss:
      hidePanel()

    case .startSearch:
      break
    }
  }

  // MARK: - Panel

  private func showPanel() {
    guard let service else { return }
    // Refresh the sidebar on every show: collections can be renamed, created, or
    // deleted from the context menu while the panel is closed, and a stale list
    // would offer scopes that no longer exist.
    panelModel.setCollections(TaskCache.shared.collections)
    panelModel.replaceItems(service.items)
    panelModel.query = ""
    if panelModel.selection == nil {
      panelModel.selection = panelModel.visibleItems.first?.id
    }

    if panel == nil {
      panel = makePanel()
    }
    guard let panel else { return }

    panel.center()
    // `orderFrontRegardless`, not `orderFront`: the latter can be refused while
    // another app holds focus.
    panel.orderFrontRegardless()
    panel.makeKey()
    startKeyMonitor()
  }

  private func hidePanel() {
    keyMonitor.stop()
    panel?.orderOut(nil)
    panelModel.selection = nil
  }

  // MARK: - Collections

  /// Prompts for a collection name and creates it.
  ///
  /// A plain text field rather than a sheet: collection names are short, and a
  /// sheet on a non-activating panel is awkward to drive.
  private func promptForCollectionName() {
    guard let service else { return }
    guard
      let name = Self.askForText(
        title: "New Collection",
        message: "Name",
        initial: ""
      )
    else { return }

    Task { @MainActor in
      _ = await service.makeCollection(name: name)
      panelModel.setCollections(TaskCache.shared.collections)
      panelModel.replaceItems(service.items)
    }
  }

  private func promptForRename(_ id: UUID) {
    guard let service else { return }
    let current = TaskCache.shared.collections.first { $0.id == id }?.name ?? ""
    guard
      let name = Self.askForText(
        title: "Rename Collection",
        message: "Name",
        initial: current
      )
    else { return }

    Task { @MainActor in
      await service.renameCollection(id, to: name)
      panelModel.setCollections(TaskCache.shared.collections)
    }
  }

  /// Single-line text prompt. Returns nil when cancelled.
  private static func askForText(
    title: String,
    message: String,
    initial: String
  ) -> String? {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    let field = NSTextField(string: initial)
    field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
    alert.accessoryView = field
    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "Cancel")

    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  // MARK: - Auxiliary panels

  private var transformPanel: NSPanel?
  private var previewPanel: NSPanel?
  private let transformModel = TransformModel()

  private func makeAuxiliaryPanel(
    hosting view: some View,
    width: CGFloat,
    height: CGFloat
  ) -> NSPanel {
    let panel = ClipPanel(
      contentRect: NSRect(x: 0, y: 0, width: width, height: height),
      styleMask: [.nonactivatingPanel, .fullSizeContentView, .resizable],
      backing: .buffered,
      defer: false
    )
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.hidesOnDeactivate = false
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.contentView = NSHostingView(rootView: view)
    return panel
  }

  func showTransforms(for item: ClipItem) {
    transformModel.load(item)
    if let existing = transformPanel {
      existing.contentView = NSHostingView(rootView: transformContent())
    } else {
      transformPanel = makeAuxiliaryPanel(
        hosting: transformContent(),
        width: 720,
        height: 460
      )
    }
    transformPanel?.center()
    transformPanel?.orderFrontRegardless()
    transformPanel?.makeKey()
  }

  private func transformContent() -> some View {
    TransformSheet(
      model: transformModel,
      onApply: { [weak self] text in
        // The transformed text becomes a new clip rather than replacing the
        // original: you usually want to keep what you copied.
        self?.service?.copyTextAsNewClip(text, derivedFrom: self?.transformModel.item)
        self?.transformPanel?.orderOut(nil)
      },
      onDismiss: { [weak self] in self?.transformPanel?.orderOut(nil) }
    )
  }

  func showPreview(for item: ClipItem) {
    if previewPanel == nil {
      previewPanel = makeAuxiliaryPanel(
        hosting: ClipPreviewView(item: item),
        width: 560,
        height: 420
      )
    } else {
      previewPanel?.contentView = NSHostingView(rootView: ClipPreviewView(item: item))
    }
    previewPanel?.center()
    previewPanel?.orderFrontRegardless()
    previewPanel?.makeKey()
  }

  private func makePanel() -> ClipPanel? {
    let content = ClipListView(
      model: panelModel,
      collections: TaskCache.shared.collections,
      onCopy: { [weak self] item in
        self?.service?.copy(item)
        self?.hidePanel()
      },
      onPaste: { [weak self] item in
        self?.service?.paste(item)
        self?.hidePanel()
      },
      onTogglePin: { [weak self] item in
        self?.service?.togglePin(item)
      },
      onDelete: { [weak self] item in
        self?.service?.delete(item)
      },
      onSearch: { [weak self] query in
        guard let self else { return }
        self.service?.search(query)
        if let service = self.service {
          self.panelModel.replaceItems(service.items)
        }
      },
      onDismiss: { [weak self] in self?.hidePanel() },
      onTransform: { [weak self] item in self?.showTransforms(for: item) },
      onPreview: { [weak self] item in self?.showPreview(for: item) },
      onFile: { [weak self] item, id in self?.service?.file(item, into: id) },
      onToggleLock: { [weak self] item in
        self?.service?.toggleLock(item)
        if let service = self?.service {
          self?.panelModel.replaceItems(service.items)
        }
      },
      onClearHistory: { [weak self] in
        guard let self, let service = self.service else { return }
        Task { @MainActor in
          await service.clearAll(includingPinned: true)
          self.panelModel.replaceItems(service.items)
        }
      },
      onCreateCollection: { [weak self] in self?.promptForCollectionName() },
      onRenameCollection: { [weak self] id in self?.promptForRename(id) },
      onDeleteCollection: { [weak self] id in
        guard let self, let service = self.service else { return }
        Task { @MainActor in
          await service.deleteCollection(id)
          self.panelModel.setCollections(TaskCache.shared.collections)
          self.panelModel.replaceItems(service.items)
        }
      },
      rejection: service?.lastRejection
    )

    let panel = ClipPanel(
      contentRect: NSRect(x: 0, y: 0, width: 420, height: 460),
      styleMask: [.nonactivatingPanel, .fullSizeContentView, .resizable],
      backing: .buffered,
      defer: false
    )
    panel.isFloatingPanel = true
    panel.level = .floating
    // `NSPanel` defaults this to true, which would hide the panel whenever the
    // user clicks away.
    panel.hidesOnDeactivate = false
    panel.isMovable = false
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.contentView = NSHostingView(rootView: content)
    return panel
  }

  private func togglePanelAction() {
    if panel?.isVisible == true {
      hidePanel()
    } else {
      hotKeyPressed()
    }
  }

  // MARK: - Permissions

  /// macOS 15.4 added a pasteboard permission that is inert through 26 and
  /// enforced by default on 27. Checked on launch so the user learns about it
  /// from us rather than hitting a silent failure.
  private func checkPasteboardAccess() {
    switch PasteboardAccessCompat.state {
    case .denied:
      presentError(PasteboardAccessDenied())
    case .requiresApproval:
      presentError(PasteboardAccessApproval())
    case .unrestricted, .none:
      break
    }
  }

  private func presentError(_ error: Error) {
    let alert = NSAlert()
    alert.messageText = "sijil"
    alert.informativeText = error.localizedDescription
    alert.addButton(withTitle: "OK")
    NSApp.activate(ignoringOtherApps: true)
    alert.runModal()
  }

  private func presentFatal(_ error: Error) {
    let alert = NSAlert()
    alert.messageText = "sijil could not start"
    alert.informativeText = error.localizedDescription
    alert.addButton(withTitle: "Quit")
    NSApp.activate(ignoringOtherApps: true)
    alert.runModal()
    NSApp.terminate(nil)
  }
}

private struct PasteboardAccessDenied: LocalizedError {
  var errorDescription: String? {
    "Clipboard access is denied for sijil in System Settings ▸ Privacy & Security ▸ "
      + "Paste from Other Apps. Nothing will be recorded until it is allowed."
  }
}

private struct PasteboardAccessApproval: LocalizedError {
  var errorDescription: String? {
    "macOS may ask for permission to read the clipboard. Allow it in System Settings "
      + "▸ Privacy & Security ▸ Paste from Other Apps."
  }
}

/// Carries the migration notice verbatim.
private struct LegacyMigrationNotice: LocalizedError {
  init(_ message: String) { self.message = message }
  private let message: String
  var errorDescription: String? { message }
}

/// Carries the signature-change explanation verbatim, which is why it wraps a
/// string rather than computing one.
private struct SignatureChangedError: LocalizedError {
  init(_ message: String) { self.message = message }
  private let message: String
  var errorDescription: String? { message }
}

/// Shown when `showSettingsWindow:` has no receiver.
///
/// That means the `Settings` scene is missing from the `App` body, which is
/// exactly the bug that shipped once. Reporting it beats a menu bar item that
/// looks clickable and does nothing.
private struct SettingsUnavailableError: LocalizedError {
  var errorDescription: String? {
    "The settings window could not be opened. This is a bug in sijil: the "
      + "Settings scene is not registered with the app."
  }
}

/// Supplies the environment the settings panes read from.
///
/// A `Settings` scene is not part of the main view tree, so the objects the
/// panes expect in the environment have to be injected here. Without this the
/// panes render with no `Settings` in scope and crash the moment the window
/// opens — the menu bar item looked fine right up until it was clicked.
struct SettingsScene: View {
  @Bindable var delegate: AppDelegate

  var body: some View {
    SettingsView()
      .environment(delegate.settings)
      .environment(delegate.clipboardService)
  }
}

struct SettingsView: View {
  @Environment(Settings.self) private var settings

  var body: some View {
    TabView {
      CaptureSettings()
        .tabItem { Label("Capture", systemImage: "square.and.pencil") }
      PrivacySettings()
        .tabItem { Label("Privacy", systemImage: "hand.raised") }
      VaultSettings()
        .tabItem { Label("Vault", systemImage: "folder") }
    }
    .frame(width: 520, height: 420)
  }
}

struct CaptureSettings: View {
  @Environment(Settings.self) private var settings

  var body: some View {
    @Bindable var settings = settings
    Form {
      Toggle("Record clipboard history", isOn: $settings.rules.isCapturing)
      Toggle("Record images", isOn: $settings.rules.capturesImages)
      Toggle(
        "Ignore Universal Clipboard (Handoff)", isOn: $settings.rules.ignoresUniversalClipboard)
      Picker("Check interval", selection: $settings.pollInterval) {
        Text("Fast (0.2s)").tag(TimeInterval(0.2))
        Text("Normal (0.4s)").tag(TimeInterval(0.4))
        Text("Relaxed (1.0s)").tag(TimeInterval(1.0))
      }
    }
    .formStyle(.grouped)
    .onChange(of: settings.rules) { _, _ in
      NotificationCenter.default.post(name: .sijilRulesChanged, object: nil)
    }
    .onChange(of: settings.pollInterval) { _, _ in
      NotificationCenter.default.post(name: .sijilRulesChanged, object: nil)
    }
  }
}

struct PrivacySettings: View {
  @Environment(Settings.self) private var settings
  @Environment(ClipboardService.self) private var service

  var body: some View {
    @Bindable var settings = settings
    Form {
      Section {
        Text(
          "Clips marked confidential by the source app are never recorded. "
            + "This cannot be turned off."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        Toggle("Don't record passwords and API keys", isOn: $settings.rules.detectsSecrets)
        Text(
          "Copies from password managers are dropped outright. Everything else is "
            + "checked for private keys, tokens, API keys, card numbers, and "
            + "credential-bearing URLs before it can reach disk."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        if case .secretDetected(let kind) = service.lastRejection {
          Label("Last copy dropped: \(kind.description)", systemImage: "eye.slash")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }

      Section("Ignored apps") {
        Text(
          settings.rules.ignoredApps.isEmpty
            ? "None. Add bundle identifiers to skip an app's copies."
            : settings.rules.ignoredApps.sorted().joined(separator: "\n")
        )
        .font(.callout)
      }

      Section("Ignore patterns") {
        Text(
          settings.rules.ignoredPatterns.isEmpty
            ? "None. Regular expressions matched against copied text."
            : settings.rules.ignoredPatterns.joined(separator: "\n")
        )
        .font(.callout)
      }

      Section("Synthetic paste") {
        LabeledContent("Accessibility", value: Accessibility.isTrusted ? "Granted" : "Not granted")
        Text(
          Accessibility.isTrusted
            ? "sijil can send ⌘V to the app you were using."
            : "Without Accessibility, sijil copies and you press ⌘V yourself."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        Button("Open Accessibility Settings") {
          Accessibility.openSettings()
        }
      }

      Section("Startup") {
        Toggle("Open sijil at login", isOn: $settings.launchAtLogin)
        if let error = settings.launchAtLoginError {
          Label(error, systemImage: "exclamationmark.triangle")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
  }
}

struct VaultSettings: View {
  @Environment(Settings.self) private var settings

  var body: some View {
    @Bindable var settings = settings
    Form {
      Section {
        LabeledContent("Folder", value: settings.vaultURL.path)
        Text(
          "Point this at an iCloud Drive, Dropbox, Google Drive, or Obsidian "
            + "folder and the sync client you already run keeps it in step."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        Button("Choose Folder…") { chooseVault() }
        Button("Reveal in Finder") {
          NSWorkspace.shared.activateFileViewerSelecting([settings.vaultURL])
        }
      }

      Section("Retention") {
        LabeledContent(
          "Full-fidelity window",
          value: settings.retention.fullFidelityWindow.isFinite
            ? "\(Int(settings.retention.fullFidelityWindow / 86_400)) days"
            : "Forever"
        )
        LabeledContent(
          "Maximum items",
          value: settings.retention.maximumItems.map(String.init) ?? "Unlimited"
        )
        Text("Pinned items and collections are never pruned.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      Section("Maintenance") {
        Button("Flush to Vault Now") {
          NotificationCenter.default.post(name: .sijilFlushVault, object: nil)
        }
        Button("Rebuild Index From Vault") {
          NotificationCenter.default.post(name: .sijilRebuildVault, object: nil)
        }
        Button("Compact Database Now") {
          NotificationCenter.default.post(name: .sijilCompact, object: nil)
        }
        Text(
          "Compaction reclaims the space freed by deletions and merges the search "
            + "index. It runs automatically when enough is at stake to be worth it."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }

  private func chooseVault() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.directoryURL = settings.vaultURL
    panel.prompt = "Use Folder"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    settings.vaultRootPath = url.path
  }
}

extension Notification.Name {
  static let sijilRulesChanged = Notification.Name("com.buamod.sijil.rulesChanged")
  static let sijilFlushVault = Notification.Name("com.buamod.sijil.flushVault")
  static let sijilRebuildVault = Notification.Name("com.buamod.sijil.rebuildVault")
  static let sijilCompact = Notification.Name("com.buamod.sijil.compact")
}
