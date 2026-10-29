import AppKit
import Carbon.HIToolbox

/// The shortcut that shows the history and steps down it. Adding ⇧ steps up, so only this base is chosen
/// and stored.
struct HotKey: Equatable {
    /// A Carbon virtual key code.
    let keyCode: UInt32
    /// Carbon modifiers: any of ⌃ ⌥ ⌘, never ⇧.
    let modifiers: UInt32
    /// The key as the user's layout shows it ("V").
    let keyLabel: String

    static let standard = HotKey(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey | cmdKey), keyLabel: "V")

    private static let defaultsKey = "hotKey"

    static func == (lhs: HotKey, rhs: HotKey) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.modifiers == rhs.modifiers
    }

    /// The chosen shortcut, or the standard one if none was chosen.
    static var current: HotKey {
        guard let stored = UserDefaults.standard.dictionary(forKey: defaultsKey),
              let keyCode = stored["keyCode"] as? Int,
              let modifiers = stored["modifiers"] as? Int,
              let keyLabel = stored["keyLabel"] as? String else { return .standard }
        return HotKey(keyCode: UInt32(keyCode), modifiers: UInt32(modifiers), keyLabel: keyLabel)
    }

    /// Remembers this shortcut. The standard one is remembered as no choice at all.
    func save() {
        if self == .standard {
            UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        } else {
            UserDefaults.standard.set(["keyCode": Int(keyCode), "modifiers": Int(modifiers), "keyLabel": keyLabel],
                                      forKey: Self.defaultsKey)
        }
    }

    // MARK: The shortcut and its ⇧ variant

    var reverseModifiers: UInt32 { modifiers | UInt32(shiftKey) }
    var label: String { Self.symbols(for: modifiers) + keyLabel }
    var reverseLabel: String { Self.symbols(for: reverseModifiers) + keyLabel }

    /// The modifiers as AppKit reports them while they're held, with ⇧ for the step-up variant.
    func eventModifiers(reverse: Bool) -> NSEvent.ModifierFlags {
        let carbon = reverse ? reverseModifiers : modifiers
        var flags: NSEvent.ModifierFlags = []
        if carbon & UInt32(controlKey) != 0 { flags.insert(.control) }
        if carbon & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbon & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if carbon & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return flags
    }

    /// Whether macOS itself uses this shortcut or its ⇧ variant (Spotlight's ⌘Space, the screenshots' ⇧⌘3, and so
    /// on). Registering one succeeds all the same and macOS acts on it too, so this is the only way to know. A
    /// shortcut that another app registers can't be detected.
    var usedByMacOS: Bool {
        var list: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&list) == noErr, let entries = list?.takeRetainedValue() as? [[String: Any]] else { return false }
        let mask = Int(cmdKey | shiftKey | optionKey | controlKey)
        let ours = [Int(modifiers), Int(reverseModifiers)]
        return entries.contains { entry in
            guard entry[kHISymbolicHotKeyEnabled as String] as? Bool == true,
                  entry[kHISymbolicHotKeyCode as String] as? Int == Int(keyCode),
                  let modifiers = entry[kHISymbolicHotKeyModifiers as String] as? Int else { return false }
            return ours.contains(modifiers & mask)
        }
    }

    /// In the order macOS writes them: ⌃⌥⇧⌘.
    private static func symbols(for modifiers: UInt32) -> String {
        [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
            .filter { modifiers & UInt32($0.0) != 0 }
            .map(\.1)
            .joined()
    }

    // MARK: Recording

    /// Why a key press can't be the shortcut; the text is shown to the user.
    enum Rejection: String, Error {
        case needsModifier = "Hold ⌃, ⌥ or ⌘ together with the key."
        case hasShift = "Leave ⇧ out: it's added to step up the list."
        case clipboardChord = "⌘C, ⌘X and ⌘V are how every app copies and pastes, and this app pastes with ⌘V."
        case unsupportedKey = "That key can't be used."
        case usedByMacOS = "macOS already uses this shortcut, or its ⇧ version, which steps up the list."
    }

    private static let specialKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "⎋",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7",
        kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13",
        kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19",
        kVK_F20: "F20",
    ]

    /// The shortcut a key press spells, or why it can't be one.
    static func recorded(from event: NSEvent) -> Result<HotKey, Rejection> {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.contains(.shift) else { return .failure(.hasShift) }
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        guard modifiers != 0 else { return .failure(.needsModifier) }

        let keyCode = Int(event.keyCode)
        guard let keyLabel = specialKeys[keyCode] ?? event.charactersIgnoringModifiers?.uppercased(),
              let first = keyLabel.unicodeScalars.first, !CharacterSet.controlCharacters.contains(first)
        else { return .failure(.unsupportedKey) }
        if modifiers == UInt32(cmdKey), [kVK_ANSI_C, kVK_ANSI_X, kVK_ANSI_V].contains(keyCode) {
            return .failure(.clipboardChord)
        }
        let hotKey = HotKey(keyCode: UInt32(keyCode), modifiers: modifiers, keyLabel: keyLabel)
        if hotKey.usedByMacOS { return .failure(.usedByMacOS) }
        return .success(hotKey)
    }
}
