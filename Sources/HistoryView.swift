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
        didSet { selection = store.items.first(where: matches)?.id }
    }
    /// The emoji tab being shown; nil is All. The history always opens on All, so row 1 is the newest copy.
    @Published var tab: String? {
        didSet { selection = store.items.first(where: matches)?.id }
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
    /// Whether the confirmation is for the restorable clear.
    var clearIsRestorable = false
    /// The entry whose deletion is being confirmed, because it is marked to ask first; also over the list.
    @Published var confirmingDelete: UUID?
    /// The entry being marked (⌘T), in a panel over the list like the help.
    @Published var marking: UUID?
    /// Which emoji of `palette` the arrow keys are on, and what has been typed or pasted for another one.
    @Published var markCursor = 0
    @Published var markText = ""
    /// The images whose text is being read for the text button, which goes on when the panel is closed.
    @Published var recognizing: Set<UUID> = []
    /// The images that were read and gave nothing on a Mac that can't read every script (see
    /// `ClipboardStore.unreadableLanguages`): not known to be empty, so their text button is orange, and pressing it
    /// reads again. Kept for this run only, so a later macOS update reads them.
    @Published var unreadable: [UUID: String] = [:]
    /// A line shown over the list for a few seconds, then gone on its own.
    @Published var notice: String?
    private var noticeNumber = 0

    func show(notice text: String) {
        notice = text
        noticeNumber += 1
        let number = noticeNumber
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.noticeNumber == number { self?.notice = nil }
        }
    }
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
    /// Pops up the … menu, which the panel builds (see `HistoryPanel.showMoreMenu`).
    var onShowMenu: () -> Void = {}

    init(store: ClipboardStore) {
        self.store = store
    }

    /// Matches the copy's text, and what its row shows about it: its kind ("image", "rich text") and the name
    /// of the app it came from.
    var filtered: [ClipboardItem] {
        store.items.filter(matches)
    }

    /// In the shown tab, and matching the search: its text, its kind, the app it came from, or an emoji it's marked with.
    private func matches(_ item: ClipboardItem) -> Bool {
        if let tab, item.tags?.contains(tab) != true { return false }
        return query.isEmpty
            || item.searchText.localizedCaseInsensitiveContains(query)
            || item.kindLabel.localizedCaseInsensitiveContains(query)
            || ItemIcons.appName(for: item.sourceBundleID)?.localizedCaseInsensitiveContains(query) == true
            || item.tags?.contains(where: { $0.contains(query) }) == true
    }

    /// The entry with this id, if it is in the filtered list.
    private func shown(_ id: UUID?) -> ClipboardItem? {
        store.items.first { $0.id == id && matches($0) }
    }

    var selectedItem: ClipboardItem? {
        shown(selection)
    }

    func setRowFrame(_ frame: CGRect, for id: UUID) {
        guard rowFrames[id] != frame else { return }
        rowFrames[id] = frame
        rowFrameChanged.send(id)
    }

    /// The entry the preview beside the panel shows.
    var previewedItem: ClipboardItem? {
        guard !showingHelp, !confirmingClear, confirmingDelete == nil, marking == nil else { return nil }
        return shown(hovered) ?? selectedItem
    }

    /// Whether the pointer is on the preview, which keeps the hovered row's preview up.
    private var pointerOnPreview = false
    private var releaseHover: DispatchWorkItem?

    /// The pointer came onto a row: its preview is the one shown.
    func rowHoverBegan(_ id: UUID) {
        releaseHover?.cancel()
        hovered = id
    }

    /// The pointer left a row. Its preview stays a moment so the pointer can travel to it (a long text scrolls),
    /// and then the preview goes back to the selection's, unless the pointer has come onto another row or the preview.
    func rowHoverEnded(_ id: UUID) {
        releaseHover?.cancel()
        guard hovered == id else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.hovered == id, !self.pointerOnPreview else { return }
            self.hovered = nil
        }
        releaseHover = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// The pointer entered or left the preview. `release: false` is for a preview that has gone away, which
    /// reports nothing.
    func previewHoverChanged(_ inside: Bool, release: Bool = true) {
        pointerOnPreview = inside
        if !inside, release, let id = hovered { rowHoverEnded(id) }
    }

    func presented() {
        pointerOnPreview = false
        tab = nil
        query = ""
        showingHelp = false
        confirmingClear = false
        confirmingDelete = nil
        marking = nil
        presentation += 1
    }

    /// The next (or previous, with a negative `offset`) tab, All included, wrapping around.
    func moveTab(by offset: Int) {
        let all: [String?] = [nil] + store.tabs
        guard all.count > 1 else { return }
        let current = all.firstIndex { $0 == tab } ?? 0
        tab = all[(current + offset + all.count) % all.count]
    }

    /// Back to All when the shown tab has no entries left.
    private func leaveEmptyTab() {
        if let tab, !store.tabs.contains(tab) { self.tab = nil }
    }

    func moveSelection(by offset: Int) {
        let items = filtered
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == selection } ?? -1
        selection = items[min(max(current + offset, 0), items.count - 1)].id
    }

    /// Steps one entry down (or up, when `reverse`), wrapping around the ends; returns whether it wrapped.
    func cycleSelection(reverse: Bool) -> Bool {
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
        let index = items.firstIndex { $0.id == item.id } ?? 0
        let wasSelected = item.id == selection
        store.delete(item)
        if wasSelected {
            let remaining = filtered
            selection = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id
        }
        leaveEmptyTab()
    }

    /// Deletes the entry, or first asks if it is marked to.
    func requestDelete(_ item: ClipboardItem) {
        if item.asksBeforeDelete == true {
            confirmingDelete = item.id
        } else {
            delete(item)
        }
    }

    func deleteSelected() {
        selectedItem.map(requestDelete)
    }

    /// The confirmation was accepted.
    func confirmDelete() {
        let id = confirmingDelete
        confirmingDelete = nil
        store.items.first { $0.id == id }.map(delete)
    }

    func clearHistory() {
        confirmingClear = false
        store.clear(restorable: clearIsRestorable)
        selection = nil
        leaveEmptyTab()
    }

    // MARK: Marks

    /// The emoji offered for marking: a few to start with (the first nine on keys 1 to 9), then any others in use.
    static let startingEmoji = ["⭐️", "❤️", "🔥", "✅", "⚠️", "💡", "📌", "🔑", "📎"]

    var palette: [String] {
        Self.startingEmoji + store.tabs.filter { !Self.startingEmoji.contains($0) }
    }

    /// An emoji, as opposed to a digit or a letter (digits are "emoji" to Unicode, as a keycap's base).
    static func isEmoji(_ character: Character) -> Bool {
        let scalars = character.unicodeScalars
        guard let first = scalars.first, first.properties.isEmoji else { return false }
        return first.value > 0xFF || scalars.count > 1
    }

    /// The emoji with its variation selector, so ❤ and ❤️ are one tab and draw in color.
    static func normalized(_ emoji: Character) -> String {
        let scalars = emoji.unicodeScalars
        if scalars.count == 1, let first = scalars.first, !first.properties.isEmojiPresentation {
            return String(emoji) + "\u{FE0F}"
        }
        return String(emoji)
    }

    func beginMarking() {
        guard let item = selectedItem else { return }
        markText = ""
        markCursor = 0
        marking = item.id
    }

    /// Marks the entry with `emoji` alone, or with `adding` (⌘) as one more among its others, or off if it's there.
    func chooseTag(_ emoji: String, adding: Bool) {
        guard let marking else { return }
        if adding {
            store.toggleTag(emoji, for: marking)
        } else {
            store.setOnlyTag(emoji, for: marking)
        }
        leaveEmptyTab()
    }

    func moveMarkCursor(by offset: Int) {
        let count = palette.count
        markCursor = (markCursor + offset + count) % count
    }

    /// Return with nothing typed: the emoji the arrow keys are on.
    func chooseHighlightedTag(adding: Bool) {
        guard palette.indices.contains(markCursor) else { return }
        chooseTag(palette[markCursor], adding: adding)
    }

    /// Return with something typed or pasted: its first emoji, or a beep if it has none.
    func chooseTypedEmoji(adding: Bool) {
        let typed = markText
        markText = ""
        guard let emoji = typed.first(where: Self.isEmoji) else { return NSSound.beep() }
        chooseTag(Self.normalized(emoji), adding: adding)
    }

    /// Pinned: deleting the entry asks first. The pin button on a row, and the marking panel's toggle.
    func togglePin(_ id: UUID) {
        guard let item = store.items.first(where: { $0.id == id }) else { return }
        store.setAsksBeforeDelete(item.asksBeforeDelete != true, for: id)
    }

    func confirmClear(restorable: Bool) {
        guard !store.items.isEmpty else { return }
        clearIsRestorable = restorable
        confirmingClear = true
    }

    func restoreCleared() {
        store.restoreCleared()
        selection = store.items.first(where: matches)?.id
    }
}

/// Tab strip height; the preview's top limit moves down by this much while there are tabs.
let tabStripHeight: CGFloat = 34

struct HistoryView: View {
    @ObservedObject var model: HistoryViewModel
    @ObservedObject var store: ClipboardStore
    @FocusState private var searchFocused: Bool
    @FocusState private var markFocused: Bool

    var body: some View {
        let items = model.filtered
        VStack(spacing: 0) {
            header
            Divider().padding(.horizontal, 16)
            ZStack {
                // The tab strip is part of the list, under the overlays, so they keep the whole area below the header.
                VStack(spacing: 0) {
                    if !store.tabs.isEmpty { tabStrip }
                    if items.isEmpty {
                        VStack(spacing: 10) {
                            Text(store.items.isEmpty ? "No Clipboard History" : "No Results")
                                .font(.system(size: 15))
                                .foregroundStyle(.secondary)
                            if store.items.isEmpty && !store.cleared.isEmpty {
                                Button("Restore \(store.cleared.count) Cleared \(store.cleared.count == 1 ? "Entry" : "Entries")") {
                                    model.restoreCleared()
                                }
                                Text("Return restores")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        list(items)
                    }
                }
                // Over the list rather than in its place, so the list keeps its scroll position.
                if model.showingHelp {
                    HelpView { model.showingHelp = false }
                }
                if let notice = model.notice {
                    Text(notice)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(.regularMaterial))
                        .padding(.bottom, 12)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
                if let id = model.marking, let item = store.items.first(where: { $0.id == id }) {
                    markPanel(item)
                }
                if let id = model.confirmingDelete, let item = store.items.first(where: { $0.id == id }) {
                    ConfirmDeleteView(item: item,
                                      onCancel: { model.confirmingDelete = nil },
                                      onDelete: { model.confirmDelete() })
                }
                if model.confirmingClear {
                    ConfirmClearView(count: store.items.count, marked: store.items.filter(\.isMarked).count,
                                     restorable: model.clearIsRestorable,
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
        .animation(.easeOut(duration: 0.2), value: model.notice)
        .onAppear { searchFocused = true }
        .onChange(of: model.presentation) { _, _ in
            DispatchQueue.main.async { searchFocused = true }
        }
        // The marking panel has a field of its own, for an emoji that isn't offered; the search gets the keyboard back.
        .onChange(of: model.marking) { _, id in
            DispatchQueue.main.async {
                if id == nil { searchFocused = true } else { markFocused = true }
            }
        }
    }

    /// All, then one tab per emoji in use, each labelled by the emoji. ← → switch while the search is empty.
    private var tabStrip: some View {
        HStack(spacing: 4) {
            tabButton("All", for: nil)
            ForEach(store.tabs, id: \.self) { emoji in
                tabButton(emoji, for: emoji)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: tabStripHeight)
    }

    private func tabButton(_ label: String, for tab: String?) -> some View {
        Button { model.tab = tab } label: {
            Text(label)
                .font(.system(size: tab == nil ? 12 : 15, weight: .medium))
                .foregroundStyle(model.tab == tab ? .primary : .secondary)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Capsule().fill(model.tab == tab ? Color.primary.opacity(0.1) : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(tab == nil ? "All entries (← →)" : "Entries marked \(label) (← →)")
    }

    /// Marks the entry: emoji to toggle (the first nine on keys 1 to 9, or ← → and Return), a field for another one,
    /// and whether deleting it asks first. Over the list like the help, so the panel keeps the keyboard.
    private func markPanel(_ item: ClipboardItem) -> some View {
        let palette = model.palette
        return VStack(spacing: 16) {
            VStack(spacing: 3) {
                Text("Mark Entry")
                    .font(.system(size: 15, weight: .semibold))
                Text(item.title)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 420)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(44), spacing: 6), count: 9), spacing: 6) {
                ForEach(Array(palette.enumerated()), id: \.element) { index, emoji in
                    let on = item.tags?.contains(emoji) == true
                    Button {
                        model.markCursor = index
                        model.chooseTag(emoji, adding: NSEvent.modifierFlags.contains(.command))
                    } label: {
                        Text(emoji)
                            .font(.system(size: 24))
                            .frame(width: 44, height: 44)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(on ? Color.accentColor.opacity(0.3) : Color.primary.opacity(0.06)))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.primary.opacity(index == model.markCursor ? 0.5 : 0), lineWidth: 1.5))
                            .overlay(alignment: .topLeading) {
                                if index < 9 {
                                    Text(String(index + 1))
                                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                        .padding(3)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            TextField("Another emoji: type or paste, then Return", text: $model.markText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .focused($markFocused)
                .padding(.vertical, 7)
                .frame(width: 320)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
            Button { model.togglePin(item.id) } label: {
                HStack(spacing: 8) {
                    Image(systemName: item.asksBeforeDelete == true ? "pin.fill" : "pin")
                        .foregroundStyle(item.asksBeforeDelete == true ? Color.accentColor : .secondary)
                    Text("Pinned: ask before deleting")
                    Text("⌘P")
                        .foregroundStyle(.tertiary)
                }
                .font(.system(size: 13))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text("1–9, or ← → and Return, pick an emoji · add ⌘ to keep the others too · ⌘T or Esc closes")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
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
            Button { model.onShowMenu() } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 20, minHeight: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .frame(height: panelHeaderHeight)
    }

    private func list(_ items: [ClipboardItem]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        let isImage = item.isImage
                        HistoryRow(item: item, store: store, isSelected: item.id == model.selection,
                                   number: index < 9 ? index + 1 : nil,
                                   onOpenInPreview: isImage ? { model.onOpenInPreview(item) } : nil,
                                   onRecognizeText: isImage ? { model.onPasteRecognizedText(item) } : nil,
                                   isRecognizing: model.recognizing.contains(item.id),
                                   unreadableNote: model.unreadable[item.id],
                                   onPasteAsPlainText: item.hasPlainTextAlternative ? { model.onPasteAsPlainText(item) } : nil,
                                   onCopy: { model.onCopy(item) },
                                   onPin: { model.togglePin(item.id) },
                                   onMark: { model.selection = item.id; model.beginMarking() },
                                   onDelete: { model.requestDelete(item) })
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
                        // Leaving the row hands the preview back to the selection, after a moment (see `rowHoverEnded`).
                        .onHover { inside in
                            if inside {
                                model.rowHoverBegan(item.id)
                            } else {
                                model.rowHoverEnded(item.id)
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
    /// The image was read on a Mac that can't read every script and gave nothing, so it may hold text that Mac can't
    /// read: the text button is orange and says so.
    let unreadableNote: String?
    /// Set for rich text and links only.
    let onPasteAsPlainText: (() -> Void)?
    let onCopy: () -> Void
    /// Pins or unpins this entry: pinned, deleting it asks first.
    let onPin: () -> Void
    /// Opens the marking panel for this entry.
    let onMark: () -> Void
    let onDelete: () -> Void

    /// The row's own hover, for its buttons. The model's `hovered` is cleared by keyboard moves (it drives the
    /// preview), and would hide the buttons from a row the pointer still rests on.
    @State private var isHovering = false
    @State private var hoverDelay: Task<Void, Never>?

    /// The image was read and has no text, so its text button is dimmed and does nothing.
    private var hasNoText: Bool { item.hasImageText == false }

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
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    // After the title, which gives way first, so a long title never hides its marks.
                    if let tags = item.tags {
                        Text(tags.joined(separator: " "))
                            .font(.system(size: 12))
                            .fixedSize()
                            .layoutPriority(1)
                    }
                    if item.asksBeforeDelete == true {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .layoutPriority(1)
                            .help("Pinned: asks before deleting")
                    }
                }
                Text("\(item.kindDetail) · @ \(item.copiedLabel)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                if let onOpenInPreview {
                    circleButton("eye", help: "Open in Preview", action: onOpenInPreview)
                }
                if let onRecognizeText {
                    circleButton("text.viewfinder", help: unreadableNote ?? (hasNoText ? "No text found in this image" : "Paste Text in Image"),
                                 busy: isRecognizing, dimmed: hasNoText, tint: unreadableNote == nil ? nil : .orange,
                                 action: onRecognizeText)
                }
                if let onPasteAsPlainText {
                    circleButton("textformat", help: "Paste as Plain Text (⌥Return)", action: onPasteAsPlainText)
                }
                circleButton(item.asksBeforeDelete == true ? "pin.slash" : "pin",
                             help: item.asksBeforeDelete == true ? "Unpin (deleting no longer asks first)" : "Pin (asks before deleting)",
                             action: onPin)
                circleButton("tag", help: "Mark with Emoji (⌘T)", action: onMark)
                circleButton("doc.on.doc", help: "Copy (⌘C)", action: onCopy)
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
    private func circleButton(_ symbol: String, weight: Font.Weight = .regular, help: String, busy: Bool = false, dimmed: Bool = false, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if busy {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: weight))
                }
            }
            .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
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
    /// How many of them are marked with an emoji or set to ask before deleting; Clear History takes those too.
    let marked: Int
    let restorable: Bool
    let onCancel: () -> Void
    let onClear: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "trash")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text(clearHistoryTitle)
                .font(.system(size: 15, weight: .semibold))
            Text(clearHistoryWarning(count: count, marked: marked, restorable: restorable))
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

/// Asks before deleting an entry that is marked to ask first, over the list like the Clear confirmation. ⌘⌫ again
/// deletes; Return or Esc keeps it, since Return is the key that pastes everywhere else in the panel.
struct ConfirmDeleteView: View {
    let item: ClipboardItem
    let onCancel: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "pin")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text("Delete This Pinned Entry?")
                .font(.system(size: 15, weight: .semibold))
            Text(item.title)
                .font(.system(size: 13))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Text("Pinned entries ask first. This can't be undone.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("Keep", action: onCancel)
                    .controlSize(.large)
                Button("Delete", role: .destructive, action: onDelete)
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
            .padding(.top, 4)
            Text("⌘⌫ deletes · Return or Esc keeps")
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
            ("⌘⌫", "Delete the selected entry (when the search is empty; or click a row's ✕)"),
            ("⌘T", "Mark with an emoji, which is also a tab (← → switch)"),            ("Eye button", "Open an image in Preview"),
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
    private static func keyColumnWidth(of sections: [(title: String, rows: [(keys: String, action: String)])]) -> CGFloat {
        let widest = sections.flatMap(\.rows).map { ($0.keys as NSString).size(withAttributes: [.font: keyFont]).width }.max() ?? 0
        return widest.rounded(.up) + 2
    }

    var body: some View {
        let sections = Self.sections
        let keyColumnWidth = Self.keyColumnWidth(of: sections)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Keyboard Shortcuts")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("Clipboard History \(appVersion)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            ForEach(sections, id: \.title) { section in
                VStack(alignment: .leading, spacing: 6) {
                    Text(section.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 5) {
                        ForEach(section.rows, id: \.keys) { row in
                            GridRow {
                                Text(row.keys)
                                    .font(.system(size: 13, weight: .medium))
                                    .frame(width: keyColumnWidth, alignment: .leading)
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
            guard item.filePaths.count == 1 else { return NSWorkspace.shared.icon(for: .folder) }
            let path = item.filePaths[0]
            return FileManager.default.fileExists(atPath: path)
                ? NSWorkspace.shared.icon(forFile: path)
                : NSWorkspace.shared.icon(for: UTType(filenameExtension: (path as NSString).pathExtension) ?? .data)
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
