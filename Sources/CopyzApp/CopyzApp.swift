import AppKit
import Carbon.HIToolbox
import CopyzCore
import CopyzPaste
import SwiftUI

@main
struct CopyzApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

  var body: some Scene {
    // Menu-bar-only: no Dock icon, no main window. `MenuBarExtra` supplies the
    // status item, so the delegate's hand-rolled `NSStatusItem` is not used.
    MenuBarExtra("copyz", systemImage: "doc.on.clipboard") {
      MenuBarContent(delegate: delegate)
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
    Button("Quit copyz") { NSApp.terminate(nil) }
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
  func skipNextCopy() { service?.skipNextCopy() }
  func flushVault() { Task { await service?.flushVault() } }
  func rebuildVault() { Task { await service?.rebuildFromVault() } }

  func openSettings() {
    NSApp.activate()
    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
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
    panelModel.replaceItems(service.items)
    panelModel.query = ""
    if panelModel.selection == nil {
      panelModel.selection = service.items.first?.id
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
    alert.messageText = "copyz"
    alert.informativeText = error.localizedDescription
    alert.addButton(withTitle: "OK")
    NSApp.activate(ignoringOtherApps: true)
    alert.runModal()
  }

  private func presentFatal(_ error: Error) {
    let alert = NSAlert()
    alert.messageText = "copyz could not start"
    alert.informativeText = error.localizedDescription
    alert.addButton(withTitle: "Quit")
    NSApp.activate(ignoringOtherApps: true)
    alert.runModal()
    NSApp.terminate(nil)
  }
}

private struct PasteboardAccessDenied: LocalizedError {
  var errorDescription: String? {
    "Clipboard access is denied for copyz in System Settings ▸ Privacy & Security ▸ "
      + "Paste from Other Apps. Nothing will be recorded until it is allowed."
  }
}

private struct PasteboardAccessApproval: LocalizedError {
  var errorDescription: String? {
    "macOS may ask for permission to read the clipboard. Allow it in System Settings "
      + "▸ Privacy & Security ▸ Paste from Other Apps."
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
    .frame(width: 520, height: 380)
  }
}

struct CaptureSettings: View {
  @Environment(Settings.self) private var settings

  var body: some View {
    @Bindable var settings = settings
    Form {
      Toggle("Record clipboard history", isOn: $settings.rules.isCapturing)
      Toggle("Record images", isOn: $settings.rules.capturesImages)
      Toggle("Ignore Universal Clipboard (Handoff)", isOn: $settings.rules.ignoresUniversalClipboard)
      Picker("Check interval", selection: $settings.pollInterval) {
        Text("Fast (0.2s)").tag(TimeInterval(0.2))
        Text("Normal (0.4s)").tag(TimeInterval(0.4))
        Text("Relaxed (1.0s)").tag(TimeInterval(1.0))
      }
    }
    .formStyle(.grouped)
    .onChange(of: settings.rules) { _, _ in
      NotificationCenter.default.post(name: .copyzRulesChanged, object: nil)
    }
    .onChange(of: settings.pollInterval) { _, _ in
      NotificationCenter.default.post(name: .copyzRulesChanged, object: nil)
    }
  }
}

struct PrivacySettings: View {
  @Environment(Settings.self) private var settings

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
            ? "copyz can send ⌘V to the app you were using."
            : "Without Accessibility, copyz copies and you press ⌘V yourself."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        Button("Open Accessibility Settings") {
          Accessibility.openSettings()
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
          NotificationCenter.default.post(name: .copyzFlushVault, object: nil)
        }
        Button("Rebuild Index From Vault") {
          NotificationCenter.default.post(name: .copyzRebuildVault, object: nil)
        }
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
  static let copyzRulesChanged = Notification.Name("app.copyz.rulesChanged")
  static let copyzFlushVault = Notification.Name("app.copyz.flushVault")
  static let copyzRebuildVault = Notification.Name("app.copyz.rebuildVault")
}