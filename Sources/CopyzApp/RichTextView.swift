import AppKit
import SwiftUI

/// Renders `NSAttributedString` with its original styling.
///
/// `Text` cannot take an `NSAttributedString` directly, so an `NSTextView` is
/// wrapped rather than approximating the formatting with SwiftUI modifiers —
/// which would lose fonts, colours, and inline attributes that matter for code
/// snippets and rich pastes.
struct RichTextView: NSViewRepresentable {
  let attributed: NSAttributedString

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.hasVerticalScroller = true
    scrollView.drawsBackground = false

    let textView = NSTextView()
    textView.isEditable = false
    textView.isSelectable = true
    textView.drawsBackground = false
    textView.isRichText = true
    textView.textContainerInset = .zero
    textView.textContainer?.lineFragmentPadding = 0
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]

    scrollView.documentView = textView
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let textView = scrollView.documentView as? NSTextView else { return }
    // Avoid resetting the selection on every observation pass.
    guard textView.attributedString() != attributed else { return }
    let selected = textView.selectedRange()
    textView.textStorage?.setAttributedString(attributed)
    textView.setSelectedRange(
      selected.location <= textView.textStorage?.length ?? 0
        ? selected : NSRange(location: 0, length: 0)
    )
  }
}

/// Alpha checkerboard so an image with transparency is legible.
struct Checkerboard: View {
  var step: CGFloat = 10

  var body: some View {
    Canvas { context, size in
      let light = Color.secondary.opacity(0.12)
      for row in 0..<Int(ceil(size.height / step)) {
        for column in 0..<Int(ceil(size.width / step)) {
          guard (row + column).isMultiple(of: 2) else { continue }
          context.fill(
            Path(
              CGRect(
                x: CGFloat(column) * step,
                y: CGFloat(row) * step,
                width: step,
                height: step
              )
            ),
            with: .color(light)
          )
        }
      }
    }
  }
}
