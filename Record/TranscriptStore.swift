import Foundation

struct Transcript: Identifiable, Hashable {
    let url: URL
    let date: Date

    var id: URL { url }

    var title: String {
        url.deletingPathExtension().lastPathComponent
    }

    var hasOriginal: Bool {
        TranscriptStore.originalURL(for: url) != nil
    }
}

/// Saves and lists transcripts as plain .txt files in the app's Documents folder,
/// which is exposed in the Files app (UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace).
///
/// The pre-enhancement original of an enhanced transcript is kept out of
/// Documents, in Application Support, keyed by the transcript's filename.
enum TranscriptStore {
    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var originalsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OriginalTranscripts", isDirectory: true)
    }

    private static let filenameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter
    }()

    private static let enhancedFilenameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return formatter
    }()

    private static let maximumTitleLength = 40

    @discardableResult
    static func save(_ text: String, date: Date = .now) throws -> Transcript {
        let name = "Recording \(filenameFormatter.string(from: date)).txt"
        let url = directory.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return Transcript(url: url, date: date)
    }

    static func list() -> [Transcript] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        )) ?? []
        return contents
            .filter { $0.pathExtension == "txt" }
            .map { url in
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return Transcript(url: url, date: date)
            }
            .sorted { $0.date > $1.date }
    }

    static func load(_ transcript: Transcript) -> String {
        strippingLegacyHeader(
            (try? String(contentsOf: transcript.url, encoding: .utf8)) ?? ""
        )
    }

    static func delete(_ transcript: Transcript) {
        try? FileManager.default.removeItem(at: transcript.url)
        if let originalURL = originalURL(for: transcript.url) {
            try? FileManager.default.removeItem(at: originalURL)
        }
    }

    /// Renames a transcript to a user-chosen title, carrying its hidden
    /// original along so "View original" keeps working.
    static func rename(_ transcript: Transcript, to requestedTitle: String) throws -> Transcript {
        guard let title = sanitizedTitle(requestedTitle) else {
            throw TranscriptStoreError.invalidName
        }
        let targetURL = availableURL(forBaseName: title, current: transcript.url)
        guard targetURL != transcript.url else { return transcript }

        try FileManager.default.moveItem(at: transcript.url, to: targetURL)
        if let originalURL = originalURL(for: transcript.url) {
            try? FileManager.default.moveItem(
                at: originalURL,
                to: originalsDirectory.appendingPathComponent(targetURL.lastPathComponent)
            )
        }
        return Transcript(url: targetURL, date: transcript.date)
    }

    // MARK: - Enhancement

    /// Replaces a saved raw transcript with its enhanced form: the original is
    /// preserved in Application Support first, the enhanced text is written
    /// under the generated title, and only then is the raw file removed — a
    /// crash mid-way leaves a duplicate at worst, never a loss.
    static func finalizeEnhanced(
        raw: Transcript,
        body: String,
        title: String?,
        recordedAt: Date
    ) throws -> Transcript {
        let targetURL: URL
        if let title = title.flatMap(sanitizedTitle) {
            let base = "\(title) — \(enhancedFilenameFormatter.string(from: recordedAt))"
            targetURL = availableURL(forBaseName: base, current: raw.url)
        } else {
            targetURL = raw.url
        }

        try FileManager.default.createDirectory(at: originalsDirectory, withIntermediateDirectories: true)
        let originalURL = originalsDirectory.appendingPathComponent(targetURL.lastPathComponent)
        // A re-run of enhancement already has an original stashed from the
        // first pass; carry that one forward instead of overwriting it with
        // the partially enhanced text being re-enhanced now.
        if let existingOriginalURL = Self.originalURL(for: raw.url) {
            if existingOriginalURL != originalURL {
                try? FileManager.default.removeItem(at: originalURL)
                try FileManager.default.moveItem(at: existingOriginalURL, to: originalURL)
            }
        } else {
            try? FileManager.default.removeItem(at: originalURL)
            try FileManager.default.copyItem(at: raw.url, to: originalURL)
        }

        try body.write(to: targetURL, atomically: true, encoding: .utf8)
        if targetURL != raw.url {
            try? FileManager.default.removeItem(at: raw.url)
        }
        return Transcript(url: targetURL, date: recordedAt)
    }

    /// Reduces a title to something filename-safe, or nil when nothing
    /// usable remains.
    static func sanitizedTitle(_ raw: String) -> String? {
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>")
            .union(.controlCharacters)
            .union(.newlines)
        let words = raw
            .components(separatedBy: forbidden)
            .joined(separator: " ")
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }

        var title = ""
        for word in words {
            let candidate = title.isEmpty ? word : title + " " + word
            if candidate.count > maximumTitleLength { break }
            title = candidate
        }
        if title.isEmpty {
            title = words.joined(separator: " ")
            title = String(title.prefix(maximumTitleLength))
        }

        let letterCount = title.unicodeScalars.filter(CharacterSet.letters.contains).count
        guard letterCount >= 3 else { return nil }
        return title
    }

    static func originalURL(for url: URL) -> URL? {
        let candidate = originalsDirectory.appendingPathComponent(url.lastPathComponent)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    static func loadOriginal(_ transcript: Transcript) -> String? {
        guard let url = originalURL(for: transcript.url) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Helpers

    private static func availableURL(forBaseName base: String, current: URL) -> URL {
        var candidate = directory.appendingPathComponent("\(base).txt")
        var attempt = 2
        while candidate != current, FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) (\(attempt)).txt")
            attempt += 1
        }
        return candidate
    }

    /// Earlier builds wrote a metadata header ("Summary: …" / "Tags: …",
    /// separated from the body by "---"). Headers are no longer written, but
    /// files created by those builds still carry them; strip on read.
    private static func strippingLegacyHeader(_ text: String) -> String {
        guard text.hasPrefix("Summary: ") || text.hasPrefix("Tags: ") else { return text }
        let searchLimit = text.index(text.startIndex, offsetBy: 4096, limitedBy: text.endIndex) ?? text.endIndex
        guard let separatorRange = text.range(of: "\n\n---\n\n", range: text.startIndex..<searchLimit) else {
            return text
        }
        let header = text[..<separatorRange.lowerBound]
        let isHeaderShaped = header.components(separatedBy: "\n").allSatisfy {
            $0.hasPrefix("Summary: ") || $0.hasPrefix("Tags: ")
        }
        return isHeaderShaped ? String(text[separatorRange.upperBound...]) : text
    }
}

enum TranscriptStoreError: LocalizedError {
    case invalidName

    var errorDescription: String? {
        switch self {
        case .invalidName:
            return "That name can't be used for a file. Try a name with at least a few letters."
        }
    }
}
