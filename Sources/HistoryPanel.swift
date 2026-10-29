import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

extension NSPanel {
    /// What the history and its preview share: a clear, shadowed panel that floats over every Space and over
    /// full-screen apps, and stays up when another app is active.
    func configureAsFloatingGlass() {
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
    }
}

extension NSView {
    /// A window is otherwise a rectangle: its shadow (and window screenshots) would show square corners.
    func roundCorners(_ radius: CGFloat) {
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }
}

/// A Spotlight-style floating panel. It's non-activating, so the app you were in stays
/// frontmost and receives the paste.
final class HistoryPanel: NSPanel, NSMenuDelegate {
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
    private var clearMenuItem: NSMenuItem?
    private var clearIsRestorable = false
    private var optionTimer: Timer?
    /// The shortcut's own modifiers, while they're still held from opening or stepping the history. Return and the
    /// number keys ignore them until one is let go, so holding ⌃⌘ through a step and a Return pastes the entry as
    /// it is, rather than as ⌘Return (move to the top).
    private var heldFromChord: NSEvent.ModifierFlags = []

    /// How the number row's keys map to the rows ⌘1 to ⌘9 paste. By key code, since on some layouts (AZERTY) the
    /// unshifted number row types symbols.
    private static let numberKeys: [Int: Int] = [
        kVK_ANSI_1: 1, kVK_ANSI_2: 2, kVK_ANSI_3: 3, kVK_ANSI_4: 4, kVK_ANSI_5: 5,
        kVK_ANSI_6: 6, kVK_ANSI_7: 7, kVK_ANSI_8: 8, kVK_ANSI_9: 9,
    ]

    init(store: ClipboardStore) {
        self.store = store
        model = HistoryViewModel(store: store)
        super.init(contentRect: NSRect(origin: .zero, size: panelSize),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: true)
        configureAsFloatingGlass()
        becomesKeyOnlyIfNeeded = false
        animationBehavior = .utilityWindow

        // A click on a row, with the same modifiers as Return: ⌘ moves the entry to the top, ⌥ pastes plain text.
        model.onPaste = { [weak self] in self?.paste($0, with: NSEvent.modifierFlags) }
        model.onCopy = { [weak self] in self?.copy($0) }
        // The Aa button; ⌘-click also moves the entry to the top.
        model.onPasteAsPlainText = { [weak self] in
            self?.paste($0, moveToTop: NSEvent.modifierFlags.contains(.command), plainText: true)
        }
        model.onOpenInPreview = { [weak self] in self?.openInPreview($0) }
        model.onPasteRecognizedText = { [weak self] in self?.recognizeAndPaste($0) }
        // The panel closes first, as it does for any window that takes the keyboard, and the dialog opens on the
        // next turn of the main queue, once the menu that chose it has gone.
        model.onShowMenu = { [weak self] in self?.showMoreMenu() }
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
        previewPanel.onHover = { [weak self] in self?.model.previewHoverChanged($0) }
        model.rowFrameChanged
            .filter { [weak self] in $0 == self?.previewedID }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.followPreviewedRow() }
            .store(in: &previewUpdates)
        let hostingView = NSHostingView(rootView: HistoryView(model: model, store: store))
        hostingView.roundCorners(panelCornerRadius)
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

    /// `reverse` says the history is opened by the shortcut (⇧ variant if true) rather than from the menu.
    func present(reverse: Bool? = nil) {
        // A copy made a moment ago may not be on the timer's list yet; row 1 must be the newest.
        store.poll()
        holdChord(reverse: reverse)
        // The screen of the window the paste lands on, or the pointer's (the menu bar icon's choice). Each falls back
        // to the other where it can't be told, so the panel always opens somewhere you're looking.
        let mouse = NSEvent.mouseLocation
        let pointerScreen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
        let screen: NSScreen?
        switch PanelScreen.current {
        case .window: screen = Self.screenOfFrontmostWindow() ?? pointerScreen ?? NSScreen.main
        case .pointer: screen = pointerScreen ?? Self.screenOfFrontmostWindow() ?? NSScreen.main
        }
        if let visible = screen?.visibleFrame {
            let top = visible.maxY - visible.height * 0.18
            setFrameOrigin(NSPoint(x: visible.midX - panelSize.width / 2, y: top - panelSize.height))
        }
        model.presented()
        store.warmUpTextRecognition()
        makeKeyAndOrderFront(nil)
        // Recompute the shadow from the rounded content, not the first frame's bounds.
        DispatchQueue.main.async { self.invalidateShadow() }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            if event.type == .flagsChanged {
                // Letting go of any key of the chord ends it: what is held after that is meant.
                if !event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(self.heldFromChord) { self.heldFromChord = [] }
                return event
            }
            guard event.window === self else { return event }
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

    // MARK: More menu

    /// The … button's menu. It is built here in AppKit because SwiftUI's Menu doesn't redraw while it is open,
    /// and holding ⌥ must turn Clear History into the restorable clear as the key goes down, as in the menu bar
    /// icon's menu.
    private func showMoreMenu() {
        guard let view = contentView else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        @discardableResult
        func add(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            return item
        }
        add("Change Shortcut…", #selector(changeShortcutChosen))
        menu.addItem(.separator())
        clearMenuItem = add("Clear History…", #selector(clearChosen))
        updateClearMenuItem()
        if !store.cleared.isEmpty {
            add("Restore Cleared History (\(store.cleared.count))", #selector(restoreChosen))
        }
        menu.popUp(positioning: nil, at: view.convert(mouseLocationOutsideOfEventStream, from: nil), in: view)
    }

    private func updateClearMenuItem() {
        clearIsRestorable = NSEvent.modifierFlags.contains(.option)
        clearMenuItem?.title = clearIsRestorable ? "Clear History (Restorable)…" : "Clear History…"
    }

    func menuWillOpen(_ menu: NSMenu) {
        // Common modes, so it also fires while the menu is tracking.
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.updateClearMenuItem() }
        RunLoop.main.add(timer, forMode: .common)
        optionTimer = timer
    }

    func menuDidClose(_ menu: NSMenu) {
        optionTimer?.invalidate()
        optionTimer = nil
    }

    @objc private func changeShortcutChosen() { model.onChangeShortcut() }
    @objc private func clearChosen() { model.confirmClear(restorable: clearIsRestorable) }
    @objc private func restoreChosen() { model.restoreCleared() }

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
        // The list starts under the tab strip, when there is one.
        let listTop = panelHeaderHeight + (store.tabs.isEmpty ? 0 : tabStripHeight)
        guard let frame = model.rowFrames[id] else { return listTop }
        return min(max(frame.minY, listTop), panelSize.height - frame.height)
    }

    private func hidePreview() {
        model.previewHoverChanged(false, release: false)
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
    func cycle(reverse: Bool) {
        holdChord(reverse: reverse)
        if model.cycleSelection(reverse: reverse), UserDefaults.standard.bool(forKey: soundOnWrapKey) {
            NSSound.beep()
        }
    }

    /// Notes which of the shortcut's modifiers are down right now (none when the history came from the menu).
    private func holdChord(reverse: Bool?) {
        heldFromChord = reverse.map { HotKey.current.eventModifiers(reverse: $0).intersection(NSEvent.modifierFlags) } ?? []
    }

    // Clicking anywhere outside closes the panel, like Spotlight.
    override func resignKey() {
        super.resignKey()
        dismiss()
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        // An input method composing in the search (Japanese, Chinese, Korean...) needs Return, the arrows and Esc itself.
        if (firstResponder as? NSTextView)?.hasMarkedText() == true { return false }
        // A key that arrives without the whole chord down means it was let go (a macro that sends the shortcut gives no
        // modifier-change events to see that by).
        let held = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if !held.contains(heldFromChord) { heldFromChord = [] }
        let flags = held.subtracting(heldFromChord)
        let command = flags.contains(.command)
        // The delete confirmation takes every key: ⌘⌫ again deletes, Return or Esc keeps the entry.
        if model.confirmingDelete != nil {
            switch Int(event.keyCode) {
            case kVK_Delete where command: model.confirmDelete()
            case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Escape: model.confirmingDelete = nil
            default: break
            }
            return true
        }
        if model.marking != nil { return handleMarkKey(event, flags: flags) }
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
        if command, flags.isDisjoint(with: [.control, .shift]), let digit = Self.numberKeys[Int(event.keyCode)] {
            let items = model.filtered
            if digit <= items.count {
                model.selection = items[digit - 1].id
                paste(items[digit - 1], plainText: flags.contains(.option))
            } else {
                NSSound.beep()
            }
            return true
        }
        // With nothing to paste, Return brings back what Clear History took.
        if [kVK_Return, kVK_ANSI_KeypadEnter].contains(Int(event.keyCode)), store.items.isEmpty, !store.cleared.isEmpty {
            model.restoreCleared()
            return true
        }
        switch Int(event.keyCode) {
        case kVK_UpArrow: model.moveSelection(by: -1)
        case kVK_DownArrow: model.moveSelection(by: 1)
        // With nothing typed ← → have nothing else to do, so they switch tabs (if there are any).
        case kVK_LeftArrow where model.query.isEmpty && !store.tabs.isEmpty: model.moveTab(by: -1)
        case kVK_RightArrow where model.query.isEmpty && !store.tabs.isEmpty: model.moveTab(by: 1)
        case kVK_ANSI_T where command:
            if model.selectedItem == nil { NSSound.beep() } else { model.beginMarking() }
        case kVK_Return, kVK_ANSI_KeypadEnter:
            model.selectedItem.map { paste($0, with: flags) }
        case kVK_Escape where model.showingHelp: model.showingHelp = false
        case kVK_Escape: dismiss()
        case kVK_ANSI_C where command: model.selectedItem.map(copy)
        // With a search typed, ⌘⌫ is the text field's: delete to the start of the line.
        case kVK_Delete where command && model.query.isEmpty: model.deleteSelected()
        default: return false
        }
        return true
    }

    /// The marking panel's keys: 1 to 9 pick that emoji, ← → and Return pick the highlighted one (Return picks what's
    /// typed instead, once something is), each alone, or with ⌘ as one more among the entry's others. ⌘P pins or
    /// unpins, ⌘T or Esc closes. Anything else goes to its field.
    private func handleMarkKey(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool {
        let code = Int(event.keyCode)
        let typing = !model.markText.isEmpty
        let adding = flags.contains(.command)
        switch code {
        case kVK_Escape: model.marking = nil
        case kVK_ANSI_T where adding: model.marking = nil
        case kVK_ANSI_P where adding: model.marking.map(model.togglePin)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if typing { model.chooseTypedEmoji(adding: adding) } else { model.chooseHighlightedTag(adding: adding) }
        case kVK_LeftArrow where !typing: model.moveMarkCursor(by: -1)
        case kVK_RightArrow where !typing: model.moveMarkCursor(by: 1)
        default:
            guard !typing, flags.isDisjoint(with: [.control, .option]), let digit = Self.numberKeys[code] else { return false }
            let palette = model.palette
            if digit <= palette.count { model.chooseTag(palette[digit - 1], adding: adding) } else { NSSound.beep() }
        }
        return true
    }

    private func copy(_ item: ClipboardItem) {
        dismiss()
        store.copyToPasteboard(item, moveToTop: false)
    }

    /// Pastes with the modifiers held: ⌘ moves the entry to the top, ⌥ pastes plain text.
    private func paste(_ item: ClipboardItem, with flags: NSEvent.ModifierFlags) {
        paste(item, moveToTop: flags.contains(.command), plainText: flags.contains(.option))
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
        model.unreadable[item.id] = nil
        // Already being read (the panel was closed and reopened meanwhile): the same read will do.
        guard model.recognizing.insert(item.id).inserted else { return }
        let store = store
        let started = Date()
        Task { [weak self] in
            let text = await Task.detached(priority: .userInitiated) { store.recognizeText(in: item) }.value
            guard let self else { return }
            model.recognizing.remove(item.id)
            // Nothing read on a Mac that can't read every script isn't known to be "no text", so it isn't remembered
            // as that: the button turns orange and a press reads again.
            let missed = ClipboardStore.unreadableLanguages
            var notice = ""
            if text == nil && !missed.isEmpty {
                let list = ListFormatter.localizedString(byJoining: missed)
                model.unreadable[item.id] = "Nothing read. This Mac's text recognition can't read \(list), so if the image has any, that's why."
                notice = "Nothing read. This Mac can't read \(list)."
            } else {
                store.setImageText(text, for: item.id)
            }
            let wanted = pasteWhenRead == item.id && isVisible
            NSLog("Read %d characters from an image in %.1f s%@", text?.count ?? 0, Date().timeIntervalSince(started),
                  wanted ? "" : " (kept, not pasted: the panel was closed)")
            guard wanted else { return }
            pasteWhenRead = nil
            if let text {
                paste(text: text)
            } else {
                NSSound.beep()
                if model.unreadable[item.id] != nil { model.show(notice: notice) }
            }
        }
    }

    private func paste(text: String) {
        dismiss()
        store.copyTextToPasteboard(text)
        pasteFromPasteboard()
    }
}
