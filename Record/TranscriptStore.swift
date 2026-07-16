import Foundation

struct Transcript: Identifiable, Equatable {
    let url: URL
    let date: Date

    var id: URL { url }

    var title: String {
        url.deletingPathExtension().lastPathComponent
    }
}

/// Saves and lists transcripts as plain .txt files in the app's Documents folder,
/// which is exposed in the Files app (UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace).
enum TranscriptStore {
    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private static let filenameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter
    }()

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
        (try? String(contentsOf: transcript.url, encoding: .utf8)) ?? ""
    }

    static func delete(_ transcript: Transcript) {
        try? FileManager.default.removeItem(at: transcript.url)
    }
}
