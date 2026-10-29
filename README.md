# Clipboard History

A tiny menu bar app that keeps a history of everything you copy on macOS. Press **⌃⌘V** to see it in a Spotlight-style panel, keep pressing ⌃⌘V to step through it, and press Return to paste the selected entry into the app you were in.

It does one thing well: get back something you copied and paste it, with one shortcut. There are no pinboards, snippets, sync or settings screens, and nothing to learn beyond a handful of keys (press **?** in the panel to see them all). Marking an entry with an emoji (see [Marking entries](#marking-entries)) is the one way to keep something on hand; until you use it, nothing of it shows.

![Clipboard History](screenshots/clipboard-history.png)

![Clipboard History Help](screenshots/clipboard-history-help.png)

## How it differs from macOS's built-in clipboard history

macOS 26 Tahoe added a clipboard history to Spotlight. It's a fine start, and if it covers what you need you don't need this app. Here's where they differ:

| | Clipboard History | Built-in (Spotlight) |
| --- | --- | --- |
| Open it | **⌃⌘V**, one shortcut | ⌘Space, then ⌘4 |
| Pick an entry | Press ⌃⌘V again to step down, ⌃⇧⌘V to step up (wrapping around), Return to paste | Find it in the list, then double-click it or use its button |
| How long entries stay | The last 200 copies, until you delete them, across restarts | A rolling time window (as little as 30 minutes, at most days), then they're gone |
| Passwords | Copies that password managers mark as private are never recorded | Reportedly records everything copied, passwords included |
| Turned on | As soon as it's running | Off until you turn it on |

This app also pastes back every format a copy carried (plain and rich text, HTML, files, images, colors), lets you remove a single entry (✕ on its row, or ⌘⌫), and shows which app each copy came from.

Where the built-in history is the better choice:

- **Nothing to install.** It's part of macOS and Apple maintains it. This app isn't notarized by Apple, so the first launch needs a Gatekeeper override (see [Install](#install)).
- **Old entries expire.** The built-in history forgets copies after a while. This app keeps its 200 entries on disk until they're pushed out or you delete them, so anything sensitive you copied from an app that doesn't mark it private stays there too. Entries you mark (see [Marking entries](#marking-entries)) also stay until you delete them. Use ✕, ⌘⌫ or **Clear History** for anything you don't want kept. (plain Clear History is final; the ⌥ version keeps what it cleared for up to an hour; see Menu.)

## Showing and pasting

⌃⌘V is the default shortcut. You can change it, and reset it, from the menu bar icon's menu (see [Menu](#menu)); the rest of this README uses the default. You choose only the base shortcut, and adding ⇧ to it always steps up.

- **⌃⌘V** shows the history, with the newest entry selected. The panel floats over the app you were in, which stays frontmost and receives the paste, and opens on the screen that app's window is on (the pointer's screen if that can't be told), or on the pointer's screen if you choose **Show On → Display with Pointer** in the menu bar icon's menu.
- **⌃⌘V again** (while the panel is shown) selects the next entry. Past the last entry it wraps to the first, with the system alert sound if you turn on **Sound on Wrap** in the menu bar icon's menu (off by default).
- **⌃⇧⌘V** does the same in reverse, wrapping from the first entry to the last.
- **Return** pastes the selected entry into the app you were in, and the entry keeps its place in the history. Clicking an entry does the same.
- **⌘Return** pastes it and moves it to the top of the history. ⌘-clicking an entry does the same. While you're still holding the shortcut's own keys (⌃⌘) from stepping, Return pastes the entry as it is: they count as ⌘ only once you let go of one.
- **⌥Return** pastes rich text or a link as plain text, without its formatting. ⌥-clicking does the same, and ⌥⌘ combines both (plain text, moved to the top). Other entries paste as usual with ⌥.
- **⌘1 to ⌘9** paste the first nine rows directly, by the numbers beside them (⌥⌘1 to ⌥⌘9 as plain text); they are the number-row keys, on any keyboard layout. Plain digits still go into the search.
- The selected row, and the row under the pointer, show buttons at their right edge (the rest stay uncluttered): one copies the entry to the clipboard without pasting, and **✕** deletes it from the history. Rich text and link rows also have an **Aa** button, to the left of copy, that pastes them as plain text (⌘-click it to also move the entry to the top); image rows have an **eye** button that opens the image in Preview, and a **text** button (to the left of copy) that reads the text in the image and pastes it (see [Text in images](#text-in-images)).
- A **preview** beside the panel shows more of the selected entry, or of the row under the pointer: the text of a copy that is long, multi-line or wider than its row (scrollable; past its first 4,000 characters a last line says how many more there are, such as "… 6,210 more characters", and pasting still pastes them all), or a larger image that keeps its shape (300 points on its longer side). It appears once the selection or pointer settles, level with its row, and a small chevron at the panel's edge marks the row it belongs to. Move the pointer from a row onto its preview and it stays, so a long text can be scrolled with the mouse.
- Each row shows what kind of data it holds (Text, Rich Text, Link, Image, a file type, Color), so you can step past entries that don't suit where you're pasting. Multi-line text also shows its line count, as in "Text (48 lines)", so it doesn't look like a one-line copy that starts the same way.

## Keys (while the panel is shown)

| Key | Action |
| --- | --- |
| Type | Search the history: the copied text (its first 4,000 characters), its kind ("image", "link", "rich text") or the app it came from ("chrome"). The panel opens with the search field focused. An input method that is composing (Japanese, say) gets Return, the arrows and Esc first |
| ↑ ↓ | Move the selection |
| ⌃⌘V / ⌃⇧⌘V | Next / previous entry, wrapping around (with a ding, if Sound on Wrap is on) |
| Return | Paste the selected entry, leaving it where it is in the history |
| ⌘Return | Paste the selected entry and move it to the top (or ⌘-click a row) |
| ⌥Return | Paste rich text or a link as plain text (or ⌥-click a row, or click its Aa button); ⌥⌘Return also moves it to the top |
| ⌘1 – ⌘9 | Paste the row with that number (the first nine rows are numbered); add ⌥ for plain text |
| ⌘C | Copy the selected entry to the clipboard without pasting |
| ⌘⌫ | Delete the selected entry from the history (when the search is empty; with a search typed it edits the search, as in any text field; or click a row's ✕). A pinned entry shows a confirmation: ⌘⌫ again deletes, Return or Esc keeps it |
| ⌘T | Mark the selected entry with an emoji, which is also a tab (see [Marking entries](#marking-entries); or click a row's tag button; a row's pin button pins it) |
| ← → | Switch tabs, when there are any and the search is empty |
| Text button on an image row | Paste the text read from the image (OCR) |
| ? | Show or hide all the shortcuts (when the search is empty; or click the ? button) |
| Esc | Close the shortcuts if shown, otherwise the panel (clicking outside it closes it too) |

## Marking entries

Two marks, both on a row. They are the one place this app lets you keep something on hand, and nothing of them shows until you use one.

- **Pin.** The **pin** button on a row (it shows once you hover or select the row) pins the entry, and the same button, now an unpin, takes the pin off. A small pin after the title shows it. A pinned entry asks before it is deleted: ✕ or ⌘⌫ shows a confirmation, and ⌘⌫ again deletes (Return or Esc keeps it, since Return pastes everywhere else).
- **Emoji.** Press **⌘T** (or click the **tag** button) to open a panel over the list. Press **1 to 9** (or ← → and Return) to give the entry one of the nine offered emoji; pressing the same one again takes it off. For any other emoji, type or paste it into the field and press Return. Each of these (click, number, Return) sets that emoji alone; **hold ⌘** (⌘-click, ⌘1 to ⌘9, ⌘Return) to add it to the entry's others instead, or take it off if it's already there. ⌘P in the panel pins or unpins, and ⌘T or Esc closes it. The emoji shows after the title, and the search matches it.

Once any entry carries an emoji, a strip of **tabs** appears under the search: **All**, then one tab per emoji, each labelled with it (a tab goes away when its last entry loses the emoji). Click one, or press ← → while the search is empty. A tab shows only the entries with that emoji; the search, ⌃⌘V stepping, Return, ⌘1 to ⌘9 and the preview all work within it. The history always opens on **All**, so the first press of ⌃⌘V and row 1 are still the newest copy.

An entry with an emoji, or pinned, is kept: it doesn't count towards the 200 and is never pushed out. **Clear History** still deletes everything, marked entries included, and its confirmation says how many are marked.

## Text in images

The **text** button on an image row reads the text in the image, on your Mac with macOS's own text recognition, and pastes it into the app you were in as plain text. It keeps the layout as far as it can: the indent, the blank lines between paragraphs, and the gaps between columns come back as spaces and empty lines, which matters for code, logs and tables. It's exact for the left edge and the blank lines, and close for the spacing inside a line: a table's columns line up to within about a character, and a run of several spaces inside one stretch of text that macOS doesn't split can come back as one.

It reads the languages macOS's own text recognition supports, picked automatically, including Hindi and Marathi (Devanagari), Chinese, Japanese, Korean, Arabic, Thai and Cyrillic scripts. Which scripts it can read depends on your macOS version, not on this app: macOS 27 reads all of these, while macOS 26.6.2 has no Devanagari. On a Mac that lacks any of them, an image that gives no text isn't known to be empty (it may be in a script that Mac can't read), so its text button turns orange and a line says which languages that Mac can't read. Press it again to retry, for example after updating macOS.

Small, dim line numbers beside code are the hardest thing for macOS to read: it finds some and misses others. When it finds a column of numbers, the app reads that column again at several sizes and keeps the reading most passes agree on. If the numbers read that way count steadily down the image, any it still missed between them (and beside text just above or below) are filled in, so those few numbers are inferred, not read. Nothing is filled in when the count isn't steady, such as with wrapped lines or two columns of numbers. Very pale numbers (light grey on white) can still lose some.

The first time you use it on an image, the panel stays open with a spinner on the button while the text is read. The text is then kept on disk beside the entry (in `~/Library/Application Support/ClipboardHistory/items`, removed with the entry), so every later paste of that image is immediate, even after a restart. An image with no text gives a beep, and its button dims (on a Mac that can read every script above, so it's certain).

The first read after the app starts can take a while (up to half a minute on some Macs) because macOS loads its recognition model. The app starts loading it in the background about 10 seconds after launch, and again the first time you open the history with an image in it. If you close the panel before a read finishes, the read carries on and is kept, but nothing is pasted.

## What it keeps

- Every type of data a copy carried (plain text, rich text, HTML, links, files, images, colors), so a pasted entry is exactly what was copied.
- Image copies and copied image files show a thumbnail. Each row has a badge with the icon of the app it was copied from.
- Copies that apps mark as private (password managers and others that follow [nspasteboard.org](http://nspasteboard.org)) are never recorded.
- Up to 200 entries, newest first, not counting [marked ones](#marking-entries), which are kept. Copying something in another app that's already in the history moves it to the top. Pasting or copying an entry from the history leaves it where it is, unless you paste it with ⌘Return or ⌘-click. To change the limit: `defaults write com.sandipchitale.clipboard-history maxItems -int 500`.
- Copies larger than 100 MB are skipped.
- When the app starts it records what's on the clipboard only if that isn't what was there when it last ran, so an entry you deleted or cleared doesn't come back, and one you pasted from the history doesn't move to the top, just because the app restarted.
- The history is stored in `~/Library/Application Support/ClipboardHistory` and survives restarts.

## Menu

Click the menu bar icon to open its menu. The history itself is for the shortcut, though the menu has it too:

- **Show Clipboard History (⌃⌘V)**
- **Clear History…** (also in the panel's … menu), which asks for confirmation first and then deletes everything for good. Hold ⌥ and it becomes **Clear History (Restorable)…**, which keeps what it cleared so it can be restored
- **Restore Cleared History (N)** (also in the panel's … menu, and as a button in the empty panel, where Return does it too), which appears only after a restorable clear. It puts the cleared entries back among anything copied since, without duplicates. They are kept on disk for up to an hour, and dropped sooner if you quit Clipboard History, so even this isn't a hiding place
- **Change Shortcut…** (also in the panel's … menu), which opens a small dialog. Hold ⌃, ⌥ or ⌘ and press a key, and the box shows the shortcut (and what stepping up will be). Nothing changes until you click **Set** (or press Return). The ⌫ button (or the Delete key) clears the box, the ↺ button puts the default in it, and **Cancel** (or Esc) keeps the shortcut you have. Leave ⇧ out, since it's added to step up, and ⌘C, ⌘X and ⌘V aren't allowed, since every app uses them and Clipboard History pastes with ⌘V. If macOS itself uses the shortcut or its ⇧ version (Spotlight's ⌘Space, say), the box says so and keeps what it had; a shortcut that another app registers can't be told in advance (see Notes)
- **Reset Shortcut to ⌃⌘V**, to go back to the default (dimmed while you're already using it)
- **Show On**, a submenu for which display the panel appears on when there are several: **Display with Active Window** (the default) or **Display with Pointer**. Each falls back to the other where it can't be told (no Accessibility permission, no window)
- **Sound on Wrap**, a ding when stepping past the last (or first) entry wraps around; off by default
- **Launch at Login**
- **Quit**

## Install

Clipboard History runs on macOS 26 or later, on Apple silicon and Intel Macs.

### Download (no developer tools needed)

1. Download `Clipboard-History-<version>.zip` from the [latest release](https://github.com/sandipchitale/clipboard-history/releases/latest), unzip it, and move **Clipboard History.app** to your Applications folder.
2. Clipboard History isn't notarized by Apple (notarization needs a paid Apple developer account, which this free project doesn't use), so macOS blocks it the first time. To allow it, run this once in Terminal:

   ```sh
   xattr -dr com.apple.quarantine "/Applications/Clipboard History.app"
   ```

   Or, without Terminal: try to open Clipboard History, then go to System Settings → Privacy & Security, scroll down, and click **Open Anyway**.
3. Open Clipboard History and grant **Accessibility** permission when asked (System Settings → Privacy & Security → Accessibility). Pasting needs it: the app pastes by sending ⌘V to the app you were in. Without it, choosing an entry still puts it on the clipboard.

Each release lists the zip's SHA-256 checksum, so you can check your download with `shasum -a 256 Clipboard-History-<version>.zip`.

### Build from source

If you have Apple's free command-line developer tools (`xcode-select --install`), you can build Clipboard History yourself. An app you build on your own Mac isn't blocked by Gatekeeper, so there's no step 2.

```sh
./install.sh           # builds, signs, copies to /Applications, launches
```

The first time you run it, `install.sh` creates a self-signed code-signing certificate called "Clipboard History Local Signing" in your login keychain. macOS asks for your password to trust it, and may ask once whether `codesign` can use the key (choose **Always Allow**). Every build is then signed with that certificate, so the Accessibility grant survives rebuilds. Then grant Accessibility as in step 3 above.

Builds are universal (Apple silicon and Intel).

`./build.sh` alone builds `build/Clipboard History.app` with an ad-hoc signature, and `./build.sh install` installs that. macOS treats each ad-hoc build as a new app, so you'd have to grant Accessibility again every time.

## Notes

- The shortcut and its ⇧ variant (⌃⌘V and ⌃⇧⌘V by default) are global shortcuts. If another app registers the same one, both may react and Clipboard History can't tell; pick another with **Change Shortcut…**, which refuses the ones macOS itself uses. If a shortcut can't be registered at all (an app that claimed it exclusively), it logs a message saying so.
- Accessibility permission is tied to the code signature. When it changes (for example, after an ad-hoc build), the install resets the old Accessibility entry and you grant it once more. To sign with your own certificate instead, set `CODESIGN_IDENTITY`.

## License

[MIT](LICENSE) © 2026 Sandip Chitale
