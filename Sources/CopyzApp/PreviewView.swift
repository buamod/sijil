import AppKit
import CopyzCore
import SwiftUI

/// Full-size preview of one clip.
///
/// Decoding is lazy: RTF and image bytes are only touched when the user
/// actually opens a preview, so history stays fast no matter how much rich
/// content is stored.
struct ClipPreviewView: View {
  let item: ClipItem

  @State private var rendered: RenderedContent?

  private enum RenderedContent {
    case image(NSImage)
    case attributed(NSAttributedString)
    case color(NSColor)
    case text(String)
    case files([URL])
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      header
      Divider()
      content
    }
    .padding(14)
    .frame(width: 560, height: 420)
    .background { GlassBackground() }
    .task(id: item.id) { render() }
  }

  private var header: some View {
    HStack(spacing: 8) {
      Label(item.kind.displayName, systemImage: symbolName)
        .font(.callout)
        .foregroundStyle(.secondary)
      if let app = item.sourceAppName, !app.isEmpty {
        Text("from \(app)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Text("\(item.vaultBody.count) characters")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private var content: some View {
    switch rendered {
    case .image(let image):
      ScrollView([.horizontal, .vertical]) {
        Image(nsImage: image)
          .resizable()
          .scaledToFit()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .background { Checkerboard() }

    case .attributed(let attributed):
      RichTextView(attributed: attributed)
        .frame(maxWidth: .infinity, maxHeight: .infinity)

    case .color(let color):
      VStack(spacing: 10) {
        RoundedRectangle(cornerRadius: 10)
          .fill(Color(nsColor: color))
          .frame(width: 120, height: 120)
        Text(item.plainText ?? "")
          .font(.system(.body, design: .monospaced))
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)

    case .files(let urls):
      ScrollView {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(urls, id: \.self) { url in
            HStack(spacing: 6) {
              Image(systemName: "doc")
                .foregroundStyle(.secondary)
              Text(url.lastPathComponent)
              Spacer()
              Text(url.path)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            }
            .font(.callout)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }

    case .text(let text):
      ScrollView {
        Text(text)
          .font(.system(.body, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

    case nil:
      ProgressView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private var symbolName: String {
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

  /// Decoding RTF, HTML, and images can take a few milliseconds; doing it off
  /// the main actor keeps the panel responsive while previews open.
  private func render() {
    if let color = ClipPreview.color(for: item) {
      rendered = .color(color)
      return
    }
    if let image = ClipPreview.image(for: item) {
      rendered = .image(image)
      return
    }
    if !item.fileURLs.isEmpty {
      rendered = .files(item.fileURLs)
      return
    }
    if item.kind == .richText || item.kind == .html,
       let attributed = ClipPreview.attributedText(for: item) {
      rendered = .attributed(attributed)
      return
    }
    rendered = .text(ClipPreview.text(for: item) ?? item.title)
  }
}