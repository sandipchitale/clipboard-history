import AppKit
import CryptoKit
import UniformTypeIdentifiers

/// The data of one NSPasteboardItem: every type it carried, richest first.
typealias PasteboardRepresentation = [(type: String, data: Data)]

/// What the history list shows about one copy. The copied data itself lives on disk (see ClipboardStore).
struct ClipboardItem: Identifiable, Codable, Equatable {
    enum Category: String, Codable {
        case text, richText, link, file, image, color, other
    }

    let id: UUID
    var date: Date
    let sourceBundleID: String?
    let category: Category
    let title: String
    let kindLabel: String
    let searchText: String
    let filePaths: [String]
    let colorHex: String?
    let contentHash: String
    /// Lines in a text copy; nil for other kinds, and for text saved before it was recorded.
    let lineCount: Int?
    /// Characters in a text copy, whole; `searchText` keeps only the first `searchTextLimit` of them. Nil for
    /// other kinds, and for text saved before it was recorded.
    let characterCount: Int?
    /// Whether the text button has read this image: nil if not yet, true if it found text (kept in the store, see
    /// `ClipboardStore.cachedImageText`), false if there was none.
    var hasImageText: Bool?

    private static let searchTextLimit = 4000

    /// What the preview leaves out of a text copy that's longer than `searchText`, so a cut never passes for
    /// the whole copy. Nil when nothing is left out.
    var truncationNote: String? {
        guard [.text, .richText, .link].contains(category) else { return nil }
        guard let characterCount else {
            // Saved without a length: the search text is the whole copy unless it reached its limit.
            return searchText.count >= Self.searchTextLimit ? "… and more" : nil
        }
        let hidden = characterCount - searchText.count
        guard hidden > 0 else { return nil }
        return "… \(hidden.formatted()) more \(hidden == 1 ? "character" : "characters")"
    }

    /// The kind, with the line count of a multi-line text ("Text (48 lines)"), so it doesn't look like a
    /// one-line copy that starts the same way.
    var kindDetail: String {
        guard [.text, .richText, .link].contains(category) else { return kindLabel }
        // Entries saved without a count: the search text holds the whole copy unless it reached its limit.
        let lines = lineCount ?? Self.lines(in: searchText)
        guard lines > 1 else { return kindLabel }
        let atLimit = lineCount == nil && searchText.count >= Self.searchTextLimit
        return "\(kindLabel) (\(lines.formatted())\(atLimit ? "+" : "") lines)"
    }

    /// The path of a single copied image file.
    var imageFilePath: String? {
        guard filePaths.count == 1,
              UTType(filenameExtension: (filePaths[0] as NSString).pathExtension)?.conforms(to: .image) == true
        else { return nil }
        return filePaths[0]
    }

    /// Rich text or a link, whose plain text pastes differently from the copy itself.
    var hasPlainTextAlternative: Bool {
        category == .richText || category == .link
    }

    /// An image copy, or a copied image file.
    var isImage: Bool {
        category == .image || imageFilePath != nil
    }

    /// The shortest label that's still clear: the time today, "Oct 12, 6:41 PM" earlier this year, and the year
    /// too before that ("Oct 12, 2025, 6:41 PM"). A calendar year, not a rolling window, so a label without a
    /// year is never a date that hasn't come round yet this year, and a month's entries are labelled alike.
    var copiedLabel: String {
        let time = date.formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return time
        }
        let monthAndDay = Date.FormatStyle().month(.abbreviated).day()
        let showsYear = !calendar.isDate(date, equalTo: Date(), toGranularity: .year)
        let day = showsYear ? date.formatted(monthAndDay.year()) : date.formatted(monthAndDay)
        return "\(day), \(time)"
    }

    // MARK: Capture

    static func capture(_ pasteboard: NSPasteboard) -> [PasteboardRepresentation] {
        (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type.rawValue, $0) } }
        }
    }

    init?(representations reps: [PasteboardRepresentation], sourceBundleID: String?) {
        let allTypes = reps.flatMap { $0.map(\.type) }
        guard !allTypes.isEmpty else { return nil }

        func firstData(_ type: String) -> Data? {
            for rep in reps {
                if let data = rep.first(where: { $0.type == type })?.data { return data }
            }
            return nil
        }

        id = UUID()
        date = Date()
        self.sourceBundleID = sourceBundleID
        contentHash = Self.hash(reps)

        let fileURLs = reps.compactMap { rep -> URL? in
            guard let data = rep.first(where: { $0.type == UTType.fileURL.identifier })?.data,
                  let string = String(data: data, encoding: .utf8) else { return nil }
            return URL(string: string)
        }
        let text = firstData(UTType.utf8PlainText.identifier)
            .flatMap { String(data: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let imageType = allTypes.first { UTType($0)?.conforms(to: .image) == true }
        var colorHex: String?
        var filePaths: [String] = []
        var lineCount: Int?
        var characterCount: Int?

        if !fileURLs.isEmpty {
            filePaths = fileURLs.map(\.path)
            let names = fileURLs.map(\.lastPathComponent)
            category = .file
            title = names.count == 1 ? names[0] : "\(names[0]) and \(names.count - 1) more"
            kindLabel = names.count == 1 ? Self.kindLabel(forFile: fileURLs[0]) : "\(names.count) Items"
            searchText = names.joined(separator: " ")
        } else if let text, !text.isEmpty {
            let isLink = allTypes.contains(UTType.url.identifier)
                || (!text.contains(where: \.isWhitespace) && (text.hasPrefix("http://") || text.hasPrefix("https://")))
            let isRich = allTypes.contains { [UTType.rtf.identifier, UTType.html.identifier, UTType.flatRTFD.identifier].contains($0) }
            category = isLink ? .link : isRich ? .richText : .text
            kindLabel = isLink ? "Link" : isRich ? "Rich Text" : "Text"
            let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
            title = String(firstLine.trimmingCharacters(in: .whitespaces).prefix(300))
            searchText = String(text.prefix(Self.searchTextLimit))
            lineCount = Self.lines(in: text)
            characterCount = text.count
        } else if let imageType, let data = firstData(imageType) {
            category = .image
            kindLabel = Self.titleCased(UTType(imageType)?.localizedDescription ?? "Image")
            if let source = CGImageSourceCreateWithData(data as CFData, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let width = props[kCGImagePropertyPixelWidth] as? Int,
               let height = props[kCGImagePropertyPixelHeight] as? Int {
                title = "Image \(width) × \(height)"
            } else {
                title = "Image"
            }
            searchText = kindLabel
        } else if let data = firstData("com.apple.cocoa.pasteboard.color"),
                  let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data),
                  let rgb = color.usingColorSpace(.sRGB) {
            category = .color
            kindLabel = "Color"
            let hex = String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
            colorHex = hex
            title = hex
            searchText = hex
        } else {
            category = .other
            kindLabel = "Data"
            title = Self.titleCased(UTType(allTypes[0])?.localizedDescription ?? allTypes[0])
            searchText = title
        }
        self.colorHex = colorHex
        self.filePaths = filePaths
        self.lineCount = lineCount
        self.characterCount = characterCount
    }

    // MARK: Helpers

    private static func lines(in text: String) -> Int {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
    }

    private static func hash(_ reps: [PasteboardRepresentation]) -> String {
        var hasher = SHA256()
        for rep in reps {
            for (type, data) in rep {
                hasher.update(data: Data(type.utf8))
                hasher.update(data: data)
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func kindLabel(forFile url: URL) -> String {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return "Folder"
        }
        return titleCased(UTType(filenameExtension: url.pathExtension)?.localizedDescription ?? "File")
    }

    /// "HEIF image" → "HEIF Image", leaving acronyms alone.
    private static func titleCased(_ string: String) -> String {
        string.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}
