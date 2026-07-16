import AVFoundation
import Foundation

/// Durable, temporary storage for an in-progress recording.
///
/// Audio remains here only until a transcript is successfully saved. Keeping the
/// journal in Application Support makes it possible to recover after a crash,
/// termination, or audio-session interruption without exposing recordings as
/// user documents.
struct RecordingJournal: Sendable {
    private struct Manifest: Codable {
        let id: UUID
        let startedAt: Date
    }

    let id: UUID
    let startedAt: Date
    let directory: URL

    private var manifestURL: URL { directory.appendingPathComponent("manifest.json") }
    private var checkpointURL: URL { directory.appendingPathComponent("transcript.txt") }

    static func create(date: Date = .now) throws -> RecordingJournal {
        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )

        let id = UUID()
        let journal = RecordingJournal(
            id: id,
            startedAt: date,
            directory: rootDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        )
        try FileManager.default.createDirectory(
            at: journal.directory,
            withIntermediateDirectories: true
        )
        let manifest = Manifest(id: journal.id, startedAt: journal.startedAt)
        try JSONEncoder().encode(manifest).write(to: journal.manifestURL, options: .atomic)
        return journal
    }

    static func pending() -> [RecordingJournal] {
        let directories = (try? FileManager.default.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        return directories.compactMap { directory in
            let manifestURL = directory.appendingPathComponent("manifest.json")
            guard
                let data = try? Data(contentsOf: manifestURL),
                let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
            else {
                return nil
            }
            return RecordingJournal(
                id: manifest.id,
                startedAt: manifest.startedAt,
                directory: directory
            )
        }
        .sorted { $0.startedAt < $1.startedAt }
    }

    func saveCheckpoint(_ text: String) throws {
        try text.write(to: checkpointURL, atomically: true, encoding: .utf8)
    }

    func loadCheckpoint() -> String {
        (try? String(contentsOf: checkpointURL, encoding: .utf8)) ?? ""
    }

    func audioSegmentURLs() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents
            .filter { $0.pathExtension == "caf" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func remove() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private static var rootDirectory: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return applicationSupport.appendingPathComponent("RecordingJournals", isDirectory: true)
    }
}

/// Writes SpeechAnalyzer-compatible PCM to short CAF segments on a serial queue.
/// CAF/PCM and short segments limit the amount of audio at risk if the process is
/// terminated while a file is open.
final class AudioJournalWriter: @unchecked Sendable {
    typealias FailureHandler = @Sendable (Error) -> Void

    private let queue = DispatchQueue(label: "com.mds.Record.audio-journal")
    private let journal: RecordingJournal
    private let format: AVAudioFormat
    private let maximumFramesPerSegment: AVAudioFramePosition
    private let failureHandler: FailureHandler

    private var file: AVAudioFile?
    private var framesInSegment: AVAudioFramePosition = 0
    private var nextSegmentNumber: Int
    private var firstError: Error?

    init(
        journal: RecordingJournal,
        format: AVAudioFormat,
        segmentDuration: TimeInterval = 5 * 60,
        failureHandler: @escaping FailureHandler
    ) {
        self.journal = journal
        self.format = format
        self.maximumFramesPerSegment = AVAudioFramePosition(format.sampleRate * segmentDuration)
        self.failureHandler = failureHandler
        self.nextSegmentNumber = journal.audioSegmentURLs().count + 1
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        queue.async { [self] in
            guard firstError == nil else { return }
            do {
                if file == nil || framesInSegment >= maximumFramesPerSegment {
                    try openNextSegment()
                }
                try file?.write(from: buffer)
                framesInSegment += AVAudioFramePosition(buffer.frameLength)
            } catch {
                firstError = error
                file = nil
                failureHandler(error)
            }
        }
    }

    func finish() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                file = nil
                if let firstError {
                    continuation.resume(throwing: firstError)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func openNextSegment() throws {
        file = nil
        framesInSegment = 0
        let filename = String(format: "segment-%05d.caf", nextSegmentNumber)
        nextSegmentNumber += 1
        let url = journal.directory.appendingPathComponent(filename)
        file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
    }
}
