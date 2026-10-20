import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

/// A Spotlight-style floating panel. It's non-activating, so the app you were in stays
/// frontmost and receives the paste.
final class HistoryPanel: NSPanel {
    private let store: ClipboardStore
    private let model: HistoryViewModel
    private var keyMonitor: Any?
    private let previewPanel = PreviewPanel()
    /// The entry the preview shows, or nil while it's hidden.
    private var previewedID: UUID?
    private let previewImages = NSCache<NSUUID, NSImage>()
    private var previewUpdates: Set<AnyCancellable> = []
    /// The image whose text the person is waiting to have pasted; closing the panel forgets it, so a slow read
    /// never pastes into whatever they do next. The read itself carries on, and is kept.
    private var pasteWhenRead: UUID?
    /// Opens the Change Shortcut… dialog, which the app owns.
    var onChangeShortcut: () -> Void = {}

    init(store: ClipboardStore) {
        self.store = store
        model = HistoryViewModel(store: store)
        super.init(contentRect: NSRect(origin: .zero, size: panelSize),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        animationBehavior = .utilityWindow

        // A click on a row, with the same modifiers as Return: ⌘ moves the entry to the top, ⌥ pastes plain text.
        model.onPaste = { [weak self] in
            let flags = NSEvent.modifierFlags
            self?.paste($0, moveToTop: flags.contains(.command), plainText: flags.contains(.option))
        }
        model.onCopy = { [weak self] in self?.copy($0) }
        // The Aa button; ⌘-click also moves the entry to the top.
        model.onPasteAsPlainText = { [weak self] in
            self?.paste($0, moveToTop: NSEvent.modifierFlags.contains(.command), plainText: true)
        }
        model.onOpenInPreview = { [weak self] in self?.openInPreview($0) }
        model.onPasteRecognizedText = { [weak self] in self?.recognizeAndPaste($0) }
        // The panel closes first, as it does for any window that takes the keyboard, and the dialog opens on the
        // next turn of the main queue, once the menu that chose it has gone.
        model.onChangeShortcut = { [weak self] in
            self?.dismiss()
            DispatchQueue.main.async { self?.onChangeShortcut() }
        }
        // Both publish before they change; delivering on the next turn of the main queue reads the new state.
        // A preview of another entry goes at once, and the new one waits until the selection or pointer
        // settles, so cycling or sweeping across rows doesn't flash a preview for every entry passed.
        model.objectWillChange.merge(with: store.objectWillChange)
            .receive(on: DispatchQueue.main)
            .handleEvents(receiveOutput: { [weak self] in self?.hideStalePreview() })
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.updatePreview() }
            .store(in: &previewUpdates)
        model.rowFrameChanged
            .filter { [weak self] in $0 == self?.previewedID }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.followPreviewedRow() }
            .store(in: &previewUpdates)
        let hostingView = NSHostingView(rootView: HistoryView(model: model, store: store))
        // The window is otherwise a rectangle: its shadow (and window screenshots) would show square corners.
        hostingView.wantsLayer = true
        hostingView.layer?.cornerRadius = panelCornerRadius
        hostingView.layer?.cornerCurve = .continuous
        hostingView.layer?.masksToBounds = true
        contentView = hostingView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// The screen the paste will land on: the one holding the centre of the frontmost app's focused window. Nil
    /// when that can't be told (no Accessibility permission, no window, an app that doesn't answer).
    private static func screenOfFrontmostWindow() -> NSScreen? {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              let primary = NSScreen.screens.first else { return nil }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        // Opening is the hotkey's whole job; an app that hangs mustn't hold it up.
        AXUIElementSetMessagingTimeout(application, 0.1)

        func value(of attribute: String, in element: AXUIElement) -> AXValue? {
            var result: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
            return (result as! AXValue)
        }
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let windowRef,
              let position = value(of: kAXPositionAttribute, in: windowRef as! AXUIElement),
              let size = value(of: kAXSizeAttribute, in: windowRef as! AXUIElement) else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &origin), AXValueGetValue(size, .cgSize, &extent) else { return nil }
        // Accessibility reports from the top-left of the primary screen, y down; screens are placed from the bottom-left.
        let centre = CGPoint(x: origin.x + extent.width / 2, y: primary.frame.height - (origin.y + extent.height / 2))
        return NSScreen.screens.first { $0.frame.contains(centre) }
    }

    func present() {
        // Where the paste lands, so the panel opens where you're looking; the pointer's screen if that can't be told.
        let mouse = NSEvent.mouseLocation
        let screen = Self.screenOfFrontmostWindow()
            ?? NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let top = visible.maxY - visible.height * 0.18
            setFrameOrigin(NSPoint(x: visible.midX - panelSize.width / 2, y: top - panelSize.height))
        }
        model.presented()
        store.warmUpTextRecognition()
        makeKeyAndOrderFront(nil)
        // Recompute the shadow from the rounded content, not the first frame's bounds.
        DispatchQueue.main.async { self.invalidateShadow() }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    func dismiss() {
        guard isVisible else { return }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        pasteWhenRead = nil
        hidePreview()
        orderOut(nil)
    }

    // MARK: Preview

    private func updatePreview() {
        guard isVisible, let item = model.previewedItem else { return hidePreview() }
        guard item.id != previewedID else { return }
        if let text = PreviewPanel.text(for: item) {
            previewedID = item.id
            showPreview(.text(text, note: item.truncationNote), for: item.id)
        } else if item.isImage {
            previewedID = item.id
            if let image = previewImages.object(forKey: item.id as NSUUID) {
                showPreview(.image(image), for: item.id)
                return
            }
            // Decoding a big image takes a moment; the previous preview stays up meanwhile.
            let store = store
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let image = store.previewImage(for: item, maxPixelSize: Int(PreviewPanel.imageSide * 2))
                    .map { NSImage(cgImage: $0, size: .zero) }
                DispatchQueue.main.async {
                    guard let self, self.isVisible, self.previewedID == item.id else { return }
                    guard let image else { return self.hidePreview() }
                    self.previewImages.setObject(image, forKey: item.id as NSUUID)
                    self.showPreview(.image(image), for: item.id)
                }
            }
        } else {
            hidePreview()
        }
    }

    private func hideStalePreview() {
        if previewedID != nil, !isVisible || model.previewedItem?.id != previewedID {
            hidePreview()
        }
    }

    private func showPreview(_ content: PreviewContent, for id: UUID) {
        previewPanel.show(content, beside: self, rowTop: rowTop(for: id))
        markPreviewedRow(id)
    }

    /// Keeps the preview level with its row as the list scrolls.
    private func followPreviewedRow() {
        guard let previewedID, previewPanel.isVisible else { return }
        previewPanel.move(beside: self, rowTop: rowTop(for: previewedID))
        markPreviewedRow(previewedID)
    }

    /// Points the row's chevron at the side the preview is on.
    private func markPreviewedRow(_ id: UUID?) {
        let marker = id.map { PreviewMarker(id: $0, onLeft: previewPanel.isOnLeft) }
        if model.previewMarker != marker { model.previewMarker = marker }
    }

    /// Where the row's top edge is, in points below the top of the panel. A row scrolled out of view keeps
    /// the preview at the edge of the list.
    private func rowTop(for id: UUID) -> CGFloat {
        guard let frame = model.rowFrames[id] else { return panelHeaderHeight }
        return min(max(frame.minY, panelHeaderHeight), panelSize.height - frame.height)
    }

    private func hidePreview() {
        previewedID = nil
        previewPanel.hide()
        markPreviewedRow(nil)
    }

    private func openInPreview(_ item: ClipboardItem) {
        guard let url = store.imageFileURL(for: item) else { return NSSound.beep() }
        dismiss()
        if let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") {
            NSWorkspace.shared.open([url], withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// The hotkey pressed again while shown: select the next (or previous) entry, with a ding on wrapping around
    /// if the menu bar icon's Sound on Wrap is on.
    func cycle(reverse: Bool = false) {
        if model.cycleSelection(reverse: reverse), UserDefaults.standard.bool(forKey: soundOnWrapKey) {
            NSSound.beep()
        }
    }

    // Clicking anywhere outside closes the panel, like Spotlight.
    override func resignKey() {
        super.resignKey()
        dismiss()
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        // The Clear History overlay takes every key: Return clears, Esc cancels.
        if model.confirmingClear {
            switch Int(event.keyCode) {
            case kVK_Return, kVK_ANSI_KeypadEnter: model.clearHistory()
            case kVK_Escape: model.confirmingClear = false
            default: break
            }
            return true
        }
        // ? toggles the shortcuts; with a search typed it goes into the search instead.
        if event.characters == "?", flags.isDisjoint(with: [.command, .control, .option]),
           model.query.isEmpty || model.showingHelp {
            model.showingHelp.toggle()
            return true
        }
        // ⌘1 to ⌘9 paste the numbered rows (⌥ as plain text, as everywhere); plain digits still go into the search.
        if command, flags.isDisjoint(with: [.control, .shift]),
           let digit = event.charactersIgnoringModifiers.flatMap({ Int($0) }), (1...9).contains(digit) {
            let items = model.filtered
            if digit <= items.count {
                model.selection = items[digit - 1].id
                paste(items[digit - 1], plainText: flags.contains(.option))
            } else {
                NSSound.beep()
            }
            return true
        }
        switch Int(event.keyCode) {
        case kVK_UpArrow: model.moveSelection(by: -1)
        case kVK_DownArrow: model.moveSelection(by: 1)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            model.selectedItem.map { paste($0, moveToTop: command, plainText: flags.contains(.option)) }
        case kVK_Escape where model.showingHelp: model.showingHelp = false
        case kVK_Escape: dismiss()
        case kVK_ANSI_C where command: model.selectedItem.map(copy)
        case kVK_Delete where command: model.deleteSelected()
        default: return false
        }
        return true
    }

    private func copy(_ item: ClipboardItem) {
        dismiss()
        store.copyToPasteboard(item, moveToTop: false)
    }

    /// Pastes the item into the app you were in. It keeps its place in the history unless `moveToTop` (⌘);
    /// `plainText` (⌥) pastes the plain text of rich text or a link, without formatting, and other entries as
    /// they are, so the modifiers mean the same on every key and click.
    private func paste(_ item: ClipboardItem, moveToTop: Bool = false, plainText: Bool = false) {
        let plainText = plainText && item.hasPlainTextAlternative
        dismiss()
        guard store.copyToPasteboard(item, moveToTop: moveToTop, plainText: plainText) else { return }
        pasteFromPasteboard()
    }

    /// Sends ⌘V to the app you were in, which pastes what's on the clipboard.
    private func pasteFromPasteboard() {
        guard AXIsProcessTrusted() else { requestAccessibility(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            postKeyPress(CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
        }
    }

    /// The text button on an image row: pastes the text in the image. The first time it reads the image, with the
    /// panel open and a spinner on the button, and keeps the text, so every paste after that is immediate (also
    /// after a restart). An image with no text gives a beep, and its button dims.
    private func recognizeAndPaste(_ item: ClipboardItem) {
        switch item.hasImageText {
        case true?:
            if let text = store.cachedImageText(for: item) { return paste(text: text) }
        case false?:
            return NSSound.beep()
        case nil:
            break
        }
        pasteWhenRead = item.id
        // Already being read (the panel was closed and reopened meanwhile): the same read will do.
        guard model.recognizing.insert(item.id).inserted else { return }
        let store = store
        let started = Date()
        Task { [weak self] in
            let text = await Task.detached(priority: .userInitiated) { store.recognizeText(in: item) }.value
            guard let self else { return }
            model.recognizing.remove(item.id)
            store.setImageText(text, for: item.id)
            let wanted = pasteWhenRead == item.id && isVisible
            NSLog("Read %d characters from an image in %.1f s%@", text?.count ?? 0, Date().timeIntervalSince(started),
                  wanted ? "" : " (kept, not pasted: the panel was closed)")
            guard wanted else { return }
            pasteWhenRead = nil
            if let text { paste(text: text) } else { NSSound.beep() }
        }
    }

    private func paste(text: String) {
        dismiss()
        store.copyTextToPasteboard(text)
        pasteFromPasteboard()
    }
}
