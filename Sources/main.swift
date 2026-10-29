import AppKit
import Carbon.HIToolbox
import ServiceManagement

let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
// Off unless turned on in the menu bar icon's menu.
let soundOnWrapKey = "soundOnWrap"
let panelScreenKey = "panelScreen"

/// Which screen the panel opens on. Stored by raw value; anything else (including nothing) means the window.
enum PanelScreen: String {
    case window, pointer

    static var current: PanelScreen {
        UserDefaults.standard.string(forKey: panelScreenKey).flatMap(PanelScreen.init) ?? .window
    }
}

private let eventSource = CGEventSource(stateID: .privateState)

/// Posts a key press carrying exactly `flags`; events from a private-state source
/// ignore modifiers the user is still physically holding.
func postKeyPress(_ key: CGKeyCode, flags: CGEventFlags) {
    for keyDown in [true, false] {
        let event = CGEvent(keyboardEventSource: eventSource, virtualKey: key, keyDown: keyDown)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }
}

func requestAccessibility() {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    AXIsProcessTrustedWithOptions(options)
}

let clearHistoryTitle = "Clear Clipboard History?"

/// `marked` of them carry an emoji or ask before deleting, and Clear History takes those too, so the warning says so.
func clearHistoryWarning(count: Int, marked: Int, restorable: Bool) -> String {
    let entries = "\(count) \(count == 1 ? "entry" : "entries")"
    let including = marked > 0 ? ", including \(marked) marked" : ""
    return restorable
        ? "This clears all \(entries)\(including). You can bring \(count == 1 ? "it" : "them") back from the menu for up to an hour."
        : "This deletes all \(entries)\(including). It can't be undone."
}

/// Asks before clearing the whole history. Normally that is final; `restorable` (the ⌥ menu item) keeps it
/// for a while so it can be restored.
func confirmClearHistory(_ store: ClipboardStore, restorable: Bool) {
    guard !store.items.isEmpty else { return }
    let alert = NSAlert()
    alert.messageText = clearHistoryTitle
    alert.informativeText = clearHistoryWarning(count: store.items.count, marked: store.items.filter(\.isMarked).count,
                                                restorable: restorable)
    alert.addButton(withTitle: "Clear History").hasDestructiveAction = true
    alert.addButton(withTitle: "Cancel")
    // An accessory app's alert would otherwise open behind the frontmost app.
    NSApp.activate()
    if alert.runModal() == .alertFirstButtonReturn {
        store.clear(restorable: restorable)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// Which registered hot key fired: the shortcut itself steps down, its ⇧ variant steps up.
    private static let forwardHotKeyID: UInt32 = 1
    private static let reverseHotKeyID: UInt32 = 2

    private var statusItem: NSStatusItem!
    private var clearItem: NSMenuItem?
    private var clearIsRestorable = false
    private var optionTimer: Timer?
    private var hotKeyRefs: [EventHotKeyRef?] = []
    private let store = ClipboardStore()
    private lazy var panel: HistoryPanel = {
        let panel = HistoryPanel(store: store)
        panel.onChangeShortcut = { [weak self] in self?.changeShortcut() }
        return panel
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "list.clipboard", accessibilityDescription: "Clipboard History")
        // Any click on the icon opens this menu: people click it to configure, and use the shortcut to show the history.
        let menu = NSMenu()
        // Reset is disabled when there is nothing to reset, so items are enabled by hand.
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        installEditMenu()
        installHotKeyHandler()
        registerHotKeys(HotKey.current)
        store.start()
        if !AXIsProcessTrusted() { requestAccessibility() }
        // Loading the text recognition model can take many seconds, so it starts once things have settled after
        // launch, long before the text button is pressed (see `warmUpTextRecognition`).
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [store = self.store] in store.warmUpTextRecognition() }
    }

    // MARK: Status item menu

    /// Filled each time the menu opens, so it shows the shortcut, the checkmarks and Reset's state as they are now.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let hotKey = HotKey.current
        @discardableResult
        func add(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            return item
        }
        menu.addItem(.sectionHeader(title: "Clipboard History \(appVersion)"))
        add("Show Clipboard History (\(hotKey.label))", #selector(showHistory))
        clearItem = add("Clear History…", #selector(clearHistory))
        updateClearItem()
        if !store.cleared.isEmpty {
            add("Restore Cleared History (\(store.cleared.count))", #selector(restoreClearedHistory))
        }

        menu.addItem(.separator())
        add("Change Shortcut…", #selector(changeShortcut))
        add("Reset Shortcut to \(HotKey.standard.label)", #selector(resetShortcut)).isEnabled = hotKey != .standard

        menu.addItem(.separator())
        let showOn = NSMenu(title: "Show On")
        let panelScreen = PanelScreen.current
        for (title, action, choice) in [("Display with Active Window", #selector(openOnWindowScreen), PanelScreen.window),
                                        ("Display with Pointer", #selector(openOnPointerScreen), PanelScreen.pointer)] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.state = panelScreen == choice ? .on : .off
            showOn.addItem(item)
        }
        let showOnItem = NSMenuItem(title: "Show On", action: nil, keyEquivalent: "")
        showOnItem.submenu = showOn
        menu.addItem(showOnItem)

        menu.addItem(.separator())
        add("Sound on Wrap", #selector(toggleSoundOnWrap)).state = UserDefaults.standard.bool(forKey: soundOnWrapKey) ? .on : .off
        add("Launch at Login", #selector(toggleLaunchAtLogin)).state = SMAppService.mainApp.status == .enabled ? .on : .off

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func showHistory() {
        if !panel.isVisible { panel.present() }
    }

    /// Holding ⌥ turns Clear History into the restorable clear. Set by hand, not with an alternate menu item,
    /// which didn't swap here; the title follows ⌥ while the menu is open (`menuWillOpen`).
    private func updateClearItem() {
        clearIsRestorable = NSEvent.modifierFlags.contains(.option)
        clearItem?.title = clearIsRestorable ? "Clear History (Restorable)…" : "Clear History…"
    }

    func menuWillOpen(_ menu: NSMenu) {
        // Common modes, so it also fires while the menu is tracking.
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.updateClearItem() }
        RunLoop.main.add(timer, forMode: .common)
        optionTimer = timer
    }

    func menuDidClose(_ menu: NSMenu) {
        optionTimer?.invalidate()
        optionTimer = nil
    }

    @objc private func clearHistory() {
        confirmClearHistory(store, restorable: clearIsRestorable)
    }

    @objc private func restoreClearedHistory() {
        store.restoreCleared()
    }

    @objc private func openOnWindowScreen() {
        UserDefaults.standard.set(PanelScreen.window.rawValue, forKey: panelScreenKey)
    }

    @objc private func openOnPointerScreen() {
        UserDefaults.standard.set(PanelScreen.pointer.rawValue, forKey: panelScreenKey)
    }

    @objc private func toggleSoundOnWrap() {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: soundOnWrapKey), forKey: soundOnWrapKey)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// Accessory apps have no visible menu bar, but its key equivalents still drive the search field.
    private func installEditMenu() {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = edit
        let mainMenu = NSMenu()
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    // MARK: Hotkey

    private func installHotKeyHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData!).takeUnretainedValue()
            DispatchQueue.main.async { delegate.hotKeyPressed(reverse: hotKeyID.id == AppDelegate.reverseHotKeyID) }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    /// Registers the shortcut and its ⇧ variant, replacing any registered before. Returns the labels of those
    /// that couldn't be registered, because another app or macOS uses them.
    @discardableResult
    private func registerHotKeys(_ hotKey: HotKey) -> [String] {
        unregisterHotKeys()
        var failed: [String] = []
        for (number, modifiers, label) in [(Self.forwardHotKeyID, hotKey.modifiers, hotKey.label),
                                           (Self.reverseHotKeyID, hotKey.reverseModifiers, hotKey.reverseLabel)] {
            let id = EventHotKeyID(signature: OSType(0x434C4950), id: number) // 'CLIP'
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(hotKey.keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
            if status != noErr {
                NSLog("Could not register hotkey \(label) (status \(status)); it may be taken by another app")
                failed.append(label)
            }
            hotKeyRefs.append(ref)
        }
        return failed
    }

    private func unregisterHotKeys() {
        for case let ref? in hotKeyRefs { UnregisterEventHotKey(ref) }
        hotKeyRefs = []
    }

    /// Opens the dialog that records a new shortcut (see ShortcutRecorder).
    @objc private func changeShortcut() {
        let previous = HotKey.current
        // The current shortcut would otherwise open the history instead of reaching the recorder.
        unregisterHotKeys()
        if let chosen = ShortcutRecorder.ask(current: previous) {
            use(chosen)
        } else {
            registerHotKeys(previous)
        }
    }

    @objc private func resetShortcut() {
        use(.standard)
    }

    /// Switches to `hotKey`, or stays with the current shortcut and says why not.
    private func use(_ hotKey: HotKey) {
        let previous = HotKey.current
        if registerHotKeys(hotKey).isEmpty {
            hotKey.save()
            return
        }
        registerHotKeys(previous)
        let alert = NSAlert()
        alert.messageText = "\(hotKey.label) isn't available"
        alert.informativeText = "Another app or macOS already uses \(hotKey.label) or \(hotKey.reverseLabel). The shortcut is still \(previous.label)."
        NSApp.activate()
        alert.runModal()
    }

    /// First press shows the history; each press after that steps the selection down it (up, with ⇧).
    private func hotKeyPressed(reverse: Bool) {
        if panel.isVisible {
            panel.cycle(reverse: reverse)
        } else {
            panel.present(reverse: reverse)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
