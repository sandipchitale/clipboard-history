import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

let panelSize = CGSize(width: 640, height: 540)
let panelCornerRadius: CGFloat = 26
let panelHeaderHeight: CGFloat = 58
/// The panel's own coordinate space (top-left origin), in which rows report their frames.
let panelCoordinateSpace = "panel"

/// The row the preview beside the panel shows, and which side of the panel the preview is on.
struct PreviewMarker: Equatable {
    let id: UUID
    let onLeft: Bool
}

final class HistoryViewModel: ObservableObject {
    @Published var query = "" {
        didSet { selection = filtered.first?.id }
    }
    @Published var selection: UUID? {
        // A keyboard move takes the preview back from the row under the pointer.
        didSet { hovered = nil }
    }
    /// The row under the pointer, previewed in place of the selection.
    @Published var hovered: UUID?
    @Published var showingHelp = false
    /// The Clear History confirmation, shown over the list like the help, so the panel keeps the keyboard.
    @Published var confirmingClear = false
    /// The images whose text is being read for the text button, which goes on when the panel is closed.
    @Published var recognizing: Set<UUID> = []
    /// Set by the panel while a preview is up, so its row can point a chevron at it.
    @Published var previewMarker: PreviewMarker?
    /// Bumped every time the panel is shown, so the view can refocus the search field.
    @Published private(set) var presentation = 0

    /// Each shown row's frame in the panel, so the preview can sit beside its row. Not published: it changes
    /// on every scroll, and only the preview cares, through `rowFrameChanged`.
    private(set) var rowFrames: [UUID: CGRect] = [:]
    let rowFrameChanged = PassthroughSubject<UUID, Never>()

    let store: ClipboardStore
    var onPaste: (ClipboardItem) -> Void = { _ in }
    var onCopy: (ClipboardItem) -> Void = { _ in }
    var onPasteAsPlainText: (ClipboardItem) -> Void = { _ in }
    var onOpenInPreview: (ClipboardItem) -> Void = { _ in }
    var onPasteRecognizedText: (ClipboardItem) -> Void = { _ in }
    var onChangeShortcut: () -> Void = {}

    init(store: ClipboardStore) {
        self.store = store
    }

    /// Matches the copy's text, and what its row shows about it: its kind ("image", "rich text") and the name
    /// of the app it came from.
    var filtered: [ClipboardItem] {
        guard !query.isEmpty else { return store.items }
        return store.items.filter { item in
            item.searchText.localizedCaseInsensitiveContains(query)
                || item.kindLabel.localizedCaseInsensitiveContains(query)
                || ItemIcons.appName(for: item.sourceBundleID)?.localizedCaseInsensitiveContains(query) == true
        }
    }

    var selectedItem: ClipboardItem? {
        filtered.first { $0.id == selection }
    }

    func setRowFrame(_ frame: CGRect, for id: UUID) {
        guard rowFrames[id] != frame else { return }
        rowFrames[id] = frame
        rowFrameChanged.send(id)
    }

    /// The entry the preview beside the panel shows.
    var previewedItem: ClipboardItem? {
        guard !showingHelp, !confirmingClear else { return nil }
        return filtered.first { $0.id == hovered } ?? selectedItem
    }

    func presented() {
        query = ""
        selection = filtered.first?.id
        showingHelp = false
        confirmingClear = false
        presentation += 1
    }

    func moveSelection(by offset: Int) {
        let items = filtered
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == selection } ?? -1
        selection = items[min(max(current + offset, 0), items.count - 1)].id
    }

    /// Steps one entry down (or up, when `reverse`), wrapping around the ends; returns whether it wrapped.
    @discardableResult
    func cycleSelection(reverse: Bool = false) -> Bool {
        let items = filtered
        guard !items.isEmpty else { return false }
        let step = reverse ? -1 : 1
        let next = items.firstIndex { $0.id == selection }.map { $0 + step } ?? (reverse ? items.count - 1 : 0)
        selection = items[(next + items.count) % items.count].id
        return next < 0 || next >= items.count
    }

    /// Deleting the selected entry selects its neighbour; deleting any other leaves the selection alone.
    func delete(_ item: ClipboardItem) {
        let items = filtered
        let index = items.firstIndex(of: item) ?? 0
        let wasSelected = item.id == selection
        store.delete(item)
        guard wasSelected else { return }
        let remaining = filtered
        selection = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id
    }

    func deleteSelected() {
        selectedItem.map(delete)
    }

    func clearHistory() {
        confirmingClear = false
        store.clear()
        selection = nil
    }
}

struct HistoryView: View {
    @ObservedObject var model: HistoryViewModel
    @ObservedObject var store: ClipboardStore
    @FocusState private var searchFocused: Bool

    var body: some View {
        let items = model.filtered
        VStack(spacing: 0) {
            header
            Divider().padding(.horizontal, 16)
            ZStack {
                if items.isEmpty {
                    Text(store.items.isEmpty ? "No Clipboard History" : "No Results")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    list(items)
                }
                // Over the list rather than in its place, so the list keeps its scroll position.
                if model.showingHelp {
                    HelpView { model.showingHelp = false }
                }
                if model.confirmingClear {
                    ConfirmClearView(count: store.items.count,
                                     onCancel: { model.confirmingClear = false },
                                     onClear: { model.clearHistory() })
                }
            }
        }
        .frame(width: panelSize.width, height: panelSize.height)
        .coordinateSpace(.named(panelCoordinateSpace))
        // Clipped so the help's backdrop follows the rounded corners too.
        .clipShape(RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous))
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous))
        .onAppear { searchFocused = true }
        .onChange(of: model.presentation) { _, _ in
            DispatchQueue.main.async { searchFocused = true }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "list.clipboard")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
            TextField("Clipboard", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 22))
                .focused($searchFocused)
            Button { model.showingHelp.toggle() } label: {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Keyboard Shortcuts (?)")
            Menu {
                Button("Change Shortcut…") { model.onChangeShortcut() }
                Divider()
                Button("Clear History…", role: .destructive) {
                    if !store.items.isEmpty { model.confirmingClear = true }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 18)
        .frame(height: panelHeaderHeight)
    }

    private func list(_ items: [ClipboardItem]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        HistoryRow(item: item, store: store, isSelected: item.id == model.selection,
                                   number: index < 9 ? index + 1 : nil,
                                   onOpenInPreview: item.isImage ? { model.onOpenInPreview(item) } : nil,
                                   onRecognizeText: item.isImage ? { model.onPasteRecognizedText(item) } : nil,
                                   isRecognizing: model.recognizing.contains(item.id),
                                   hasNoText: item.hasImageText == false,
                                   onPasteAsPlainText: item.hasPlainTextAlternative ? { model.onPasteAsPlainText(item) } : nil,
                                   onCopy: { model.onCopy(item) },
                                   onDelete: { model.delete(item) })
                        .id(item.id)
                        .contentShape(Rectangle())
                        .onTapGesture { model.onPaste(item) }
                        // In the gutter between the row and the panel's edge, on the preview's side.
                        .overlay(alignment: model.previewMarker?.onLeft == true ? .leading : .trailing) {
                            if let marker = model.previewMarker, marker.id == item.id {
                                Image(systemName: marker.onLeft ? "chevron.compact.left" : "chevron.compact.right")
                                    .font(.system(size: 16, weight: .heavy))
                                    .foregroundStyle(.primary.opacity(0.75))
                                    .frame(width: 8)
                                    .offset(x: marker.onLeft ? -8 : 8)
                            }
                        }
                        // Leaving the row hands the preview back to the selection.
                        .onHover { inside in
                            if inside {
                                model.hovered = item.id
                            } else if model.hovered == item.id {
                                model.hovered = nil
                            }
                        }
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(panelCoordinateSpace)) } action: {
                            model.setRowFrame($0, for: item.id)
                        }
                    }
                }
                .padding(8)
            }
            .scrollIndicators(.automatic)
            .onChange(of: model.selection) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }
}

struct HistoryRow: View {
    let item: ClipboardItem
    let store: ClipboardStore
    let isSelected: Bool
    /// 1 to 9 for the first nine rows, which ⌘1 to ⌘9 paste.
    let number: Int?
    /// Set for images only.
    let onOpenInPreview: (() -> Void)?
    /// Set for images only: pastes the text read from the image.
    let onRecognizeText: (() -> Void)?
    /// The text is being read; the buttons stay up and this one shows progress.
    let isRecognizing: Bool
    /// The image was read and has no text, so its text button is dimmed and does nothing.
    let hasNoText: Bool
    /// Set for rich text and links only.
    let onPasteAsPlainText: (() -> Void)?
    let onCopy: () -> Void
    let onDelete: () -> Void

    /// The row's own hover, for its buttons. The model's `hovered` is cleared by keyboard moves (it drives the
    /// preview), and would hide the buttons from a row the pointer still rests on.
    @State private var isHovering = false
    @State private var hoverDelay: Task<Void, Never>?

    /// Keyboard users act on the selected row, and mouse users hover a row before clicking its buttons.
    private var showsActions: Bool { isSelected || isHovering || isRecognizing }

    var body: some View {
        HStack(spacing: 10) {
            // Blank past the ninth row, so every icon lines up.
            Text(number.map(String.init) ?? "")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 8)
                .help(number.map { "Paste with ⌘\($0)" } ?? "")
            ZStack(alignment: .bottomTrailing) {
                ItemIcon(item: item, store: store)
                if let badge = ItemIcons.appIcon(for: item.sourceBundleID) {
                    Image(nsImage: badge)
                        .resizable()
                        .frame(width: 14, height: 14)
                        .offset(x: 3, y: 3)
                }
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("\(item.kindDetail) · @ \(item.copiedLabel)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                if let onOpenInPreview {
                    circleButton("eye", weight: .regular, help: "Open in Preview", action: onOpenInPreview)
                }
                if let onRecognizeText {
                    circleButton("text.viewfinder", weight: .regular, help: hasNoText ? "No text found in this image" : "Paste Text in Image",
                                 busy: isRecognizing, dimmed: hasNoText, action: onRecognizeText)
                }
                if let onPasteAsPlainText {
                    circleButton("textformat", weight: .regular, help: "Paste as Plain Text (⌥Return)", action: onPasteAsPlainText)
                }
                circleButton("doc.on.doc", weight: .regular, help: "Copy (⌘C)", action: onCopy)
                circleButton("xmark", weight: .semibold, help: "Delete from History (⌘⌫)", action: onDelete)
            }
            // Faded rather than removed, so the title keeps its width as the selection moves.
            .opacity(showsActions ? 1 : 0)
            .allowsHitTesting(showsActions)
            .animation(.easeOut(duration: 0.12), value: showsActions)
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.primary.opacity(0.1) : .clear)
        )
        // Buttons appear once the pointer rests on the row, not on every row a sweep passes; they go at once.
        .onHover { inside in
            hoverDelay?.cancel()
            guard inside else {
                isHovering = false
                return
            }
            hoverDelay = Task {
                try? await Task.sleep(for: .milliseconds(120))
                if !Task.isCancelled { isHovering = true }
            }
        }
    }

    /// `busy` swaps the symbol for a spinner of the same size, so the row doesn't shift while it works.
    private func circleButton(_ symbol: String, weight: Font.Weight, help: String, busy: Bool = false, dimmed: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if busy {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: weight))
                }
            }
            .foregroundStyle(.secondary)
            .frame(width: 26, height: 26)
            .background(Circle().fill(.quaternary))
        }
        .buttonStyle(.plain)
        .opacity(dimmed ? 0.4 : 1)
        .help(help)
    }
}

/// Asks before clearing, over the list like the help, so the panel never loses the keyboard (an alert window
/// would take it, and the panel closes when it does). Return clears, Esc cancels.
struct ConfirmClearView: View {
    let count: Int
    let onCancel: () -> Void
    let onClear: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "trash")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text("Clear Clipboard History?")
                .font(.system(size: 15, weight: .semibold))
            Text("This deletes all \(count) \(count == 1 ? "entry" : "entries"). It can't be undone.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("Cancel", action: onCancel)
                    .controlSize(.large)
                Button("Clear History", role: .destructive, action: onClear)
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
            .padding(.top, 4)
            Text("Return clears · Esc cancels")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }
}

/// Every binding, over the list; ?, Esc or a click closes it.
struct HelpView: View {
    let onClose: () -> Void

    /// Computed, not stored, so it follows a shortcut changed from the menu bar icon's menu.
    private static var sections: [(title: String, rows: [(keys: String, action: String)])] { [
        ("Anywhere", [
            (HotKey.current.label, "Show the history; press again for the next entry, wrapping around at the end"),
            (HotKey.current.reverseLabel, "Previous entry, wrapping around at the start"),
        ]),
        ("In the history", [
            ("Type", "Search the text, its kind (\"image\"), or the app it came from"),
            ("↑ ↓", "Move the selection"),
            ("Return", "Paste the selected entry, leaving it in place (or click a row)"),
            ("⌘Return", "Paste the selected entry and move it to the top (or ⌘-click a row)"),
            ("⌥Return", "Paste as plain text (or ⌥-click); add ⌘ to also move it to the top"),
            ("⌘1 – ⌘9", "Paste the row with that number, in place; add ⌥ for plain text"),
            ("⌘C", "Copy the selected entry without pasting (or click a row's copy button)"),
            ("⌘⌫", "Delete the selected entry (or click a row's ✕)"),
            ("Eye button", "Open an image in Preview"),
            ("Text button", "Paste the text read from an image (OCR)"),
            ("?", "Show or hide these shortcuts (when the search is empty)"),
            ("Esc", "Close these shortcuts, or the history"),
        ]),
        ("Menu bar icon", [
            ("Click", "Open its menu: show the history, change the shortcut, and more"),
        ]),
    ] }

    private static let keyFont = NSFont.systemFont(ofSize: 13, weight: .medium)

    /// As wide as the widest key label in any section, so the actions line up across sections and a long
    /// shortcut such as ⌃⌥⇧⌘Space never wraps.
    private static var keyColumnWidth: CGFloat {
        let widest = sections.flatMap(\.rows).map { ($0.keys as NSString).size(withAttributes: [.font: keyFont]).width }.max() ?? 0
        return widest.rounded(.up) + 2
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Keyboard Shortcuts")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("Clipboard History \(appVersion)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            ForEach(Self.sections, id: \.title) { section in
                VStack(alignment: .leading, spacing: 6) {
                    Text(section.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 5) {
                        ForEach(section.rows, id: \.keys) { row in
                            GridRow {
                                Text(row.keys)
                                    .font(.system(size: 13, weight: .medium))
                                    .frame(width: Self.keyColumnWidth, alignment: .leading)
                                Text(row.action)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial)
        .contentShape(Rectangle())
        .onTapGesture(perform: onClose)
    }
}

struct ItemIcon: View {
    let item: ClipboardItem
    let store: ClipboardStore

    var body: some View {
        if let thumbnail = ItemIcons.thumbnail(at: store.thumbnailURL(for: item)) {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        } else if item.category == .color, let hex = item.colorHex {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(hex: hex))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.separator))
                .frame(width: 28, height: 28)
        } else {
            Image(nsImage: ItemIcons.icon(for: item))
                .resizable()
                .frame(width: 32, height: 32)
        }
    }
}

enum ItemIcons {
    private static let cache = NSCache<NSString, NSImage>()
    private static let missing = NSImage()

    static func thumbnail(at url: URL) -> NSImage? {
        cached("thumb:" + url.path) { NSImage(contentsOf: url) }
    }

    private static var appNames: [String: String?] = [:]

    /// The app's name as Finder shows it ("Google Chrome"), looked up once per app.
    static func appName(for bundleID: String?) -> String? {
        guard let bundleID else { return nil }
        if let name = appNames[bundleID] { return name }
        let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { FileManager.default.displayName(atPath: $0.path) }
            .map { ($0 as NSString).deletingPathExtension }
        appNames[bundleID] = name
        return name
    }

    static func appIcon(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        return cached("app:" + bundleID) {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
        }
    }

    static func icon(for item: ClipboardItem) -> NSImage {
        switch item.category {
        case .file:
            return item.filePaths.count == 1 && FileManager.default.fileExists(atPath: item.filePaths[0])
                ? NSWorkspace.shared.icon(forFile: item.filePaths[0])
                : NSWorkspace.shared.icon(for: item.filePaths.count == 1 ? (UTType(filenameExtension: (item.filePaths[0] as NSString).pathExtension) ?? .data) : .folder)
        case .text: return NSWorkspace.shared.icon(for: .plainText)
        case .richText: return NSWorkspace.shared.icon(for: .rtf)
        case .link: return NSWorkspace.shared.icon(for: .internetLocation)
        case .image: return NSWorkspace.shared.icon(for: .image)
        case .color, .other: return NSWorkspace.shared.icon(for: .data)
        }
    }

    private static func cached(_ key: String, _ make: () -> NSImage?) -> NSImage? {
        if let image = cache.object(forKey: key as NSString) {
            return image === missing ? nil : image
        }
        let image = make()
        cache.setObject(image ?? missing, forKey: key as NSString)
        return image
    }
}

extension Color {
    init(hex: String) {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}
