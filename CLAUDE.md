# Clipboard History

A macOS 26+ menu bar app (accessory app, no Dock icon) that records everything copied and shows it in a Spotlight-style floating panel. ⌃⌘V opens it, ⌃⌘V again steps down, ⌃⇧⌘V steps up, Return pastes into the app you were in. Plain Swift (AppKit + SwiftUI + Carbon hot keys + Vision), no Xcode project, no packages. Bundle ID `com.sandipchitale.clipboard-history`, version 0.0.1 (stays 0.0.1 until the user says otherwise). `README.md` is the user-facing spec of every key and behavior; keep it in step with any change.

## Working with the owner

The owner has strong UX skills and holds that UX is a matter of paying attention. Treat their design choices as deliberate until you can show what one costs a real user.

- **Product principle:** do one thing best (get back something you copied and paste it), put a quiet smile on the user's face, let them stop noticing the interface. No pinboards, snippets, sync or settings screens. Review by subtraction and by polishing the ⌃⌘V path, never by adding features.
- **With every change you make, say why it is better UX**, grounded in that principle, and name any cost and who pays it. If there is no real UX reason, say so instead of inventing one.
- **Before proposing any cut, name what it removes and for whom.** Check whether it removes the only route to something (the … menu, the ? button, Aa, the eye and text buttons, mouse-only preview), a way to discover something, or a fallback (the menu bar icon can hide behind the notch). If it removes nothing, call it taste. Work out what job a design choice does before criticizing it; ask about intent rather than flagging a defect. Keep verified facts (with file:line) apart from taste.
- Under pushback, weigh it on its merits; don't withdraw points that still hold just to appease.

### Rejected ideas: do not propose again

- **Release-to-paste (⌘Tab-style).** Stepping never pastes, Return does, so search is one keystroke away at every moment. Any hotkey-path change must keep step-then-search. Fair game: stopping at the ends instead of wrapping, dropping the alert sound.
- **Opening on row 2.** ⌃⌘V is meant to replace ⌘V, so row 1 is not redundant. One rule: presses of ⌃⌘V = row number, then Return.
- **Fitting panel height to content.** `panelSize` (640×540, `HistoryView.swift:6`) is fixed on purpose: nothing jumps while searching, the preview and chevron stay anchored, and the Help and Clear-confirmation overlays fill the panel and would clip in a shrunken one.
- The wrap ding stays (opt-in "Sound on Wrap", off by default).

## Layout

| File | Role |
| --- | --- |
| `Sources/main.swift` | `AppDelegate`: status item and its menu (rebuilt on every open), Carbon hot key registration (forward id 1, reverse id 2), Change/Reset Shortcut, Launch at Login, Clear History confirmation. `postKeyPress` sends ⌘V from a private-state event source. |
| `Sources/HotKey.swift` | The stored shortcut (only the base is stored; ⇧ always steps up). Validates recorded keys: needs ⌃/⌥/⌘, no ⇧, not ⌘C/⌘X/⌘V, and not a shortcut macOS itself uses (`usedByMacOS`, from `CopySymbolicHotKeys`: `RegisterEventHotKey` accepts those, and another app's shortcut, without complaint, so it can't tell). Default ⌃⌘V is stored as "no choice". |
| `Sources/ShortcutRecorder.swift` | Change Shortcut… dialog. Nothing changes until Set. |
| `Sources/ClipboardStore.swift` | Polls the general pasteboard every 0.3 s, de-dupes by content hash, skips private types (nspasteboard.org list) and copies over 100 MB, persists, runs OCR (see below). `poll()` also runs as the panel opens, so row 1 is always the newest copy. Remembers the last clipboard hash (`lastClipboardHash`) so a relaunch doesn't re-record a deleted or pasted entry. Max 200 items (`defaults write com.sandipchitale.clipboard-history maxItems -int N`). |
| `Sources/ClipboardItem.swift` | Codable model and `capture` of every pasteboard representation (so a paste is exactly what was copied). |
| `Sources/HistoryPanel.swift` | Non-activating `NSPanel` (the app you were in stays frontmost and receives the paste); key monitor; present / dismiss / cycle; paste flow; preview placement. |
| `Sources/HistoryView.swift` | SwiftUI list, search, row buttons, Help and Clear overlays. |
| `Sources/PreviewPanel.swift` | Side preview (text up to 4,000 characters with a "… N more characters" note, or an image up to 300 pt) level with its row, marked by a chevron. |

Storage: `~/Library/Application Support/ClipboardHistory/` holds `index.json`, `items/<id>.plist`, `<id>.png` thumbnails and the OCR text kept beside image entries. Defaults keys: `hotKey`, `soundOnWrap`, `maxItems`, `lastClipboardHash`.

## Behavior worth remembering

- Return pastes and leaves the entry in place; ⌘Return / ⌘-click moves it to the top; ⌥ pastes plain text; ⌘1–⌘9 paste rows 1–9. Copying something already in the history from another app moves it to the top; pasting or copying from the panel does not.
- Pasting needs Accessibility permission (the app sends ⌘V). Without it the entry still lands on the clipboard. The grant is tied to the code signature.
- OCR ("text" button on image rows) uses Vision with languages picked automatically and a layout-preserving reader, plus a line-number repair pass. The Devanagari model ships inside macOS: absent on 26.6.2, present on 27.0.1. If a Devanagari read fails on some Mac, check its macOS version first; there is nothing to fix in the app. The app compares `supportedRecognitionLanguages` with the scripts the README promises: if any is missing, the text button turns orange and a retry is allowed; if all are present, "nothing read" is final and the button dims. Reading is warmed up in the background 10 s after launch and when an image is first shown; closing the panel mid-read keeps the result but pastes nothing.

- The shortcut's own modifiers (⌃⌘, with ⇧ for step up) don't count for Return and ⌘1–⌘9 while they're still held from stepping (`heldFromChord` in `HistoryPanel.swift`); letting go of one, or any key arriving without them all, ends it. Return still commits; nothing changes about when a paste happens.
- ⌘1–⌘9 match the number-row key codes (AZERTY's unshifted row types symbols). ⌘⌫ deletes only with an empty search; with a search typed it is the text field's. An input method that is composing gets Return, the arrows and Esc (`hasMarkedText`).
- A hovered row's preview stays 0.25 s after the pointer leaves the row and while it is on the preview, so a long text can be scrolled with the mouse. A text preview also shows when the one-line title is cut off (wide scripts), not just past 70 characters.
- Known, left on purpose (the owner's call): the list stays live under the Help overlay; the … menu has no Quit; plain Dvorak's ⌘V goes out as key code 9 (⌘K); ⌥ on an image row pastes the image, there is no keyboard route to its text.

## Build and run

```sh
./install.sh        # build, sign with the local self-signed cert, install to /Applications, launch (use this for development)
./build.sh          # build/Clipboard History.app, ad-hoc signed, universal (arm64 + x86_64), min macOS 26.0
./build.sh install  # install the ad-hoc build (resets the Accessibility grant every time)
```

`swiftc` is invoked directly on `Sources/*.swift` with `-swift-version 5`. There are no tests. After a change, rebuild and use the real app; the feature is the UI. `build/` is git-ignored.

Driving the app with real events (what the 2026-10-28 review did): build a scratch copy signed with the local certificate (same bundle ID, so the Accessibility grant applies), stop the installed app first (two copies would both record the clipboard and compete for ⌃⌘V), and post key events with `CGEvent` from a harness window that is frontmost. Traps: `CFFIXED_USER_HOME` isolates the history folder but **not** the preferences (cfprefsd serves the real domain, so `defaults write` under it changed the real shortcut): save and restore the real domain instead. Post modifier presses as ordinary key-down and key-up events, never as `flagsChanged` (that left ⌘ stuck in the system); release every modifier at the end. Synthetic key events typed with a unicode string never reached the search field; use key codes.

## "The drill" (the owner's term for the full release routine)

Authorized for this repo; don't re-ask before each destructive step, but verify the remote's current state before force-pushing. Take a backup first into the scratchpad (`git bundle create ... --all`, a diff of uncommitted work, the old release asset and notes).

1. If the UI changed, remake the two README screenshots (`screenshots/clipboard-history.png` 1012×586, `clipboard-history-help.png` 686×586; opaque white background, 1x), then **stop and let the owner review them before anything is committed**. Method: stage a sample history in an isolated home (`CFFIXED_USER_HOME`), run a scratch copy of the app that opens the panel itself, put a white window behind it, `screencapture -R` the region.
2. Squash everything into one root commit: `Clipboard History 0.0.1: menu bar clipboard history for macOS with ⌃⌘V paste cycling`.
3. `./build.sh`, then zip as `Clipboard-History-0.0.1.zip` with `ditto -c -k --keepParent --norsrc --noextattr`. Write release notes in the format of `build/notes.md` and include the zip's SHA-256.
4. `./install.sh` to install the signed build to /Applications.
5. Delete all previous GitHub releases and their tags (`gh release delete --cleanup-tag --yes`).
6. `git push --force-with-lease=main:<remote sha>` of the single commit, tag `v0.0.1` on it, publish the release with the zip.
7. Verify independently: one commit, one tag, one release, and the downloaded zip's checksum equals the notes.

The owner wants one clean release commit and one release, not an accumulating history.

## Conventions

- Match the surrounding Swift: `///` doc comments that say why, `// MARK:` sections, no force-unwraps beyond what is already there, user-facing strings written the way the README writes them (plain, short, ⌃⌥⇧⌘ order).
- Commit only when asked.
- Auto-memory for this project (`~/.claude/projects/-Users-sandipchitale-tools-macos-clipboard-history/memory/`) repeats the working-agreement and rejected-idea sections above in more detail.
