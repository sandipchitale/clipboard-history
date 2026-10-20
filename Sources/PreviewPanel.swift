import AppKit
import SwiftUI

/// What the preview beside the history shows: a long text, or an image larger than its thumbnail. A text
/// that's cut short carries a note saying how much is left out.
enum PreviewContent {
    case text(String, note: String?)
    case image(NSImage)
}

/// A small window beside the history panel previewing the selected (or hovered) entry. It never becomes key,
/// so the history keeps the keyboard and stays open.
final class PreviewPanel: NSPanel {
    /// Images keep their shape, with the longer side always this long.
    static let imageSide: CGFloat = 300
    private static let imagePadding: CGFloat = 8
    private static let textWidth: CGFloat = 380
    private static let maxTextHeight: CGFloat = 420
    static let textPadding: CGFloat = 14
    static let textFontSize: CGFloat = 12
    static let noteFontSize: CGFloat = 11
    static let noteSpacing: CGFloat = 8
    static let cornerRadius: CGFloat = 16
    private static let gap: CGFloat = 10

    private let hostingView = NSHostingView(rootView: PreviewView(content: nil))
    /// Whether the preview went to the left of the panel, the screen having no room on its right.
    private(set) var isOnLeft = false

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        hostingView.wantsLayer = true
        hostingView.layer?.cornerRadius = Self.cornerRadius
        hostingView.layer?.cornerCurve = .continuous
        hostingView.layer?.masksToBounds = true
        contentView = hostingView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Text worth previewing: more than one line, or more than fits in a row.
    static func text(for item: ClipboardItem) -> String? {
        guard [.text, .richText, .link].contains(item.category) else { return nil }
        let text = item.searchText
        return text.count > 70 || text.contains(where: \.isNewline) ? text : nil
    }

    /// Shows `content` to the right of `parent`, or to its left where the screen has no room, level with the
    /// row whose top edge is `rowTop` points below the top of `parent`.
    func show(_ content: PreviewContent, beside parent: NSWindow, rowTop: CGFloat) {
        hostingView.rootView = PreviewView(content: content)
        place(size: Self.size(for: content), beside: parent, rowTop: rowTop)
        if self.parent !== parent {
            parent.addChildWindow(self, ordered: .above)
        }
        orderFront(nil)
        invalidateShadow()
    }

    /// Keeps the shown preview level with its row as the row moves.
    func move(beside parent: NSWindow, rowTop: CGFloat) {
        place(size: frame.size, beside: parent, rowTop: rowTop)
    }

    private func place(size: CGSize, beside parent: NSWindow, rowTop: CGFloat) {
        let parentFrame = parent.frame
        let visible = parent.screen?.visibleFrame ?? parentFrame
        var x = parentFrame.maxX + Self.gap
        isOnLeft = x + size.width > visible.maxX
        if isOnLeft {
            x = parentFrame.minX - Self.gap - size.width
        }
        // Top-aligned with the row, pushed up where it would run off the bottom of the screen.
        let y = max(parentFrame.maxY - rowTop - size.height, visible.minY)
        setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    func hide() {
        parent?.removeChildWindow(self)
        orderOut(nil)
    }

    private static func size(for content: PreviewContent) -> CGSize {
        switch content {
        case .image(let image):
            let aspect = image.size.width / max(image.size.height, 1)
            let fitted = aspect >= 1
                ? CGSize(width: imageSide, height: max(1, (imageSide / aspect).rounded()))
                : CGSize(width: max(1, (imageSide * aspect).rounded()), height: imageSide)
            return CGSize(width: fitted.width + 2 * imagePadding, height: fitted.height + 2 * imagePadding)
        case .text(let text, let note):
            func height(of string: String, fontSize: CGFloat) -> CGFloat {
                (string as NSString).boundingRect(
                    with: CGSize(width: textWidth - 2 * textPadding, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: NSFont.systemFont(ofSize: fontSize)]).height.rounded(.up)
            }
            let noteHeight = note.map { height(of: $0, fontSize: noteFontSize) + noteSpacing } ?? 0
            // A few points spare, so SwiftUI's own line breaking never needs a scroll bar for short text.
            return CGSize(width: textWidth,
                          height: min(maxTextHeight, height(of: text, fontSize: textFontSize) + noteHeight + 2 * textPadding + 4))
        }
    }
}

struct PreviewView: View {
    let content: PreviewContent?

    var body: some View {
        Group {
            switch content {
            case .text(let text, let note):
                ScrollView {
                    VStack(alignment: .leading, spacing: PreviewPanel.noteSpacing) {
                        Text(text)
                            .font(.system(size: PreviewPanel.textFontSize))
                        if let note {
                            Text(note)
                                .font(.system(size: PreviewPanel.noteFontSize))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(PreviewPanel.textPadding)
                }
            case .image(let image):
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(8)
            case nil:
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: PreviewPanel.cornerRadius, style: .continuous))
    }
}
