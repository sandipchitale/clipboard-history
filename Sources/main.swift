import AppKit
import Carbon.HIToolbox
import ServiceManagement

let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
// Off unless turned on in the menu bar icon's menu.
let soundOnWrapKey = "soundOnWrap"

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

/// Asks before deleting the whole history, which can't be undone.
func confirmClearHistory(_ store: ClipboardStore) {
    guard !store.items.isEmpty else { return }
    let alert = NSAlert()
    alert.messageText = "Clear Clipboard History?"
    let count = store.items.count
    alert.informativeText = "This deletes all \(count) \(count == 1 ? "entry" : "entries"). It can't be undone."
    alert.addButton(withTitle: "Clear History").hasDestructiveAction = true
    alert.addButton(withTitle: "Cancel")
    // An accessory app's alert would otherwise open behind the frontmost app.
    NSApp.activate()
    if alert.runModal() == .alertFirstButtonReturn {
        store.clear()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
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
        menu.addItem(.sectionHeader(title: "Clipboard History \(appVersion)"))
        let show = NSMenuItem(title: "Show Clipboard History (\(hotKey.label))", action: #selector(showHistory), keyEquivalent: "")
        show.target = self
        menu.addItem(show)

        let clear = NSMenuItem(title: "Clear History…", action: #selector(clearHistory), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)

        menu.addItem(.separator())
        let change = NSMenuItem(title: "Change Shortcut…", action: #selector(changeShortcut), keyEquivalent: "")
        change.target = self
        menu.addItem(change)
        let reset = NSMenuItem(title: "Reset Shortcut to \(HotKey.standard.label)", action: #selector(resetShortcut), keyEquivalent: "")
        reset.target = self
        reset.isEnabled = hotKey != .standard
        menu.addItem(reset)

        menu.addItem(.separator())
        let sound = NSMenuItem(title: "Sound on Wrap", action: #selector(toggleSoundOnWrap), keyEquivalent: "")
        sound.target = self
        sound.state = UserDefaults.standard.bool(forKey: soundOnWrapKey) ? .on : .off
        menu.addItem(sound)

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func showHistory() {
        if !panel.isVisible { panel.present() }
    }

    @objc private func clearHistory() {
        confirmClearHistory(store)
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
            DispatchQueue.main.async { delegate.hotKeyPressed(reverse: hotKeyID.id == 2) }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    /// Registers the shortcut and its ⇧ variant, replacing any registered before. Returns the labels of those
    /// that couldn't be registered, because another app or macOS uses them.
    @discardableResult
    private func registerHotKeys(_ hotKey: HotKey) -> [String] {
        unregisterHotKeys()
        var failed: [String] = []
        for (number, modifiers, label) in [(UInt32(1), hotKey.modifiers, hotKey.label),
                                           (UInt32(2), hotKey.reverseModifiers, hotKey.reverseLabel)] {
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
            showHistory()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
