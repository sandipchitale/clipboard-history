import AppKit
import Carbon.HIToolbox
import SwiftUI

final class ShortcutRecorderModel: ObservableObject {
    /// The shortcut in use when the dialog opened.
    let current: HotKey
    /// What the box shows: the shortcut that Set would make current. Nil once cleared.
    @Published var draft: HotKey?
    /// Why the last key press couldn't be the shortcut.
    @Published var problem: HotKey.Rejection?

    init(current: HotKey) {
        self.current = current
        draft = current
    }

    /// Setting the shortcut already in use would change nothing.
    var canSet: Bool { draft != nil && draft != current }

    func clear() {
        draft = nil
        problem = nil
    }

    func reset() {
        draft = .standard
        problem = nil
    }
}

/// The Change Shortcut… dialog. A box shows the shortcut as it's pressed, but takes no typing; Backspace clears it
/// and Reset puts the default in it, and nothing changes until Set is clicked.
enum ShortcutRecorder {
    /// Runs the dialog and returns the shortcut to switch to, or nil if cancelled or nothing changed.
    static func ask(current: HotKey) -> HotKey? {
        let model = ShortcutRecorderModel(current: current)
        let finish = { (response: NSApplication.ModalResponse) in NSApp.stopModal(withCode: response) }

        let window = NSWindow(contentViewController: NSHostingController(
            rootView: ShortcutRecorderView(model: model, onSet: { finish(.OK) }, onCancel: { finish(.cancel) })))
        window.title = "Change Shortcut"
        window.styleMask = [.titled]
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.center()

        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let plain = event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
            if plain {
                switch Int(event.keyCode) {
                case kVK_Escape: finish(.cancel)
                case kVK_Return, kVK_ANSI_KeypadEnter: if model.canSet { finish(.OK) }
                case kVK_Delete, kVK_ForwardDelete: model.clear()
                default: record(event, in: model)
                }
            } else {
                record(event, in: model)
            }
            return nil
        }
        // An accessory app's window would otherwise open behind the frontmost app.
        NSApp.activate()
        let response = NSApp.runModal(for: window)
        window.orderOut(nil)
        monitor.map(NSEvent.removeMonitor)
        return response == .OK && model.canSet ? model.draft : nil
    }

    private static func record(_ event: NSEvent, in model: ShortcutRecorderModel) {
        switch HotKey.recorded(from: event) {
        case .success(let hotKey):
            model.draft = hotKey
            model.problem = nil
        case .failure(let rejection):
            model.problem = rejection
        }
    }
}

struct ShortcutRecorderView: View {
    @ObservedObject var model: ShortcutRecorderModel
    let onSet: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                box
                iconButton("delete.left", help: "Clear (⌫)", disabled: model.draft == nil) { model.clear() }
                iconButton("arrow.counterclockwise", help: "Reset to the default, \(HotKey.standard.label)",
                           disabled: model.draft == .standard) { model.reset() }
            }
            caption
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel", action: onCancel)
                    .controlSize(.large)
                Button("Set", action: onSet)
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canSet)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    /// Looks like an input that's waiting for a key, but is only a display.
    private var box: some View {
        Text(model.draft?.label ?? "Press the shortcut")
            .font(.system(size: model.draft == nil ? 15 : 26, weight: .medium))
            .foregroundStyle(model.draft == nil ? .tertiary : .primary)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 2))
    }

    /// What the shortcut gives, what to do, or what went wrong. Two lines tall, so nothing below it moves.
    private var caption: some View {
        Group {
            if let problem = model.problem {
                Text(problem.rawValue).foregroundStyle(.red)
            } else if let draft = model.draft {
                Text("\(draft.reverseLabel) steps up the list.\(draft == model.current ? " This is the shortcut now." : "")")
                    .foregroundStyle(.secondary)
            } else {
                Text("Hold ⌃, ⌥ or ⌘ and press a key. Leave ⇧ out: it's added to step up the list.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12))
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
    }

    private func iconButton(_ symbol: String, help: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .background(Circle().fill(.quaternary))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .help(help)
        .accessibilityLabel(help)
    }
}
