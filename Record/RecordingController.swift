import AVFoundation
import CoreMedia
import Foundation
import Speech

/// Drives the microphone -> SpeechAnalyzer pipeline and exposes live transcript text.
///
/// Audio is journaled temporarily while recording so an interrupted or terminated
/// session can be recovered. The journal is removed after a transcript is saved.
@MainActor
@Observable
final class RecordingController {
    enum State: Equatable {
        case idle
        case preparing
        case downloadingModel
        case recovering
        case recording
        case stopping
    }

    private(set) var state: State = .idle
    private(set) var finalizedText: String = ""
    private(set) var volatileText: String = ""
    var errorMessage: String?
    private(set) var lastSavedTranscript: Transcript?

    private let audioEngine = AVAudioEngine()
    private let converter = BufferConverter()
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var interruptionTask: Task<Void, Never>?
    private var engineConfigurationTask: Task<Void, Never>?

    private var journal: RecordingJournal?
    private var journalWriter: AudioJournalWriter?
    private var tapInstalled = false
    private var analysisFailure: Error?
    private var lastFinalizedResultEnd: CMTime?

    private static let strongParagraphPause: TimeInterval = 2.0
    private static let contextualParagraphPause: TimeInterval = 1.25
    private static let minimumContextualParagraphLength = 200

    var isRecording: Bool { state == .recording }
    var liveTranscript: String { finalizedText + volatileText }

    init() {
        interruptionTask = Task { [weak self] in
            for await notification in NotificationCenter.default.notifications(
                named: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance()
            ) {
                await self?.handleAudioInterruption(notification)
            }
        }

        engineConfigurationTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: .AVAudioEngineConfigurationChange
            ) {
                await self?.handleEngineConfigurationChange()
            }
        }
    }

    func toggleRecording() {
        switch state {
        case .idle:
            Task { await startRecording() }
        case .recording:
            Task { await stopRecording() }
        default:
            break
        }
    }

    /// Converts any journals left by a terminated or failed session into transcripts.
    /// Successfully recovered journals are deleted immediately afterward.
    func recoverPendingRecordingsIfNeeded() async {
        guard state == .idle else { return }

        for pendingJournal in RecordingJournal.pending() {
            state = .recovering
            errorMessage = nil
            finalizedText = ""
            volatileText = ""
            analysisFailure = nil
            lastFinalizedResultEnd = nil

            let checkpoint = pendingJournal.loadCheckpoint()
            do {
                let recovered = try await transcribeAudio(in: pendingJournal)
                let bestText = recovered.count >= checkpoint.count ? recovered : checkpoint
                let text = bestText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    throw RecordingError.noRecoverableSpeech
                }
                lastSavedTranscript = try TranscriptStore.save(text, date: pendingJournal.startedAt)
                try pendingJournal.remove()
            } catch {
                // A finalized checkpoint is still useful even if the last audio segment
                // was damaged. Keep the journal so a future launch can retry recovery.
                let text = checkpoint.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    lastSavedTranscript = try? TranscriptStore.save(text, date: pendingJournal.startedAt)
                }
                errorMessage = "An interrupted recording could not be fully recovered yet. Its temporary audio is still preserved for another attempt. \(error.localizedDescription)"
                resetAnalysisPipeline()
                state = .idle
                return
            }

            resetAnalysisPipeline()
        }

        state = .idle
    }

    // MARK: - Start

    private func startRecording() async {
        state = .preparing
        errorMessage = nil
        finalizedText = ""
        volatileText = ""
        lastSavedTranscript = nil
        analysisFailure = nil
        lastFinalizedResultEnd = nil

        do {
            guard await AVAudioApplication.requestRecordPermission() else {
                throw RecordingError.microphoneDenied
            }

            let transcriber = try await makeTranscriber()
            self.transcriber = transcriber
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            self.analyzer = analyzer
            guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                throw RecordingError.noAudioFormat
            }

            let journal = try RecordingJournal.create()
            self.journal = journal
            startResultsTask(for: transcriber, checkpointing: journal)

            let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
            self.inputBuilder = inputBuilder
            try await analyzer.start(inputSequence: inputSequence)

            converter.reset()
            journalWriter = AudioJournalWriter(
                journal: journal,
                format: analyzerFormat
            ) { [weak self] error in
                Task { @MainActor in
                    await self?.handleJournalWriteFailure(error)
                }
            }

            try startAudioEngine(analyzerFormat: analyzerFormat)
            state = .recording
        } catch {
            errorMessage = error.localizedDescription
            await abortPipeline(removeEmptyJournal: true)
            state = .idle
        }
    }

    private func makeTranscriber() async throws -> SpeechTranscriber {
        guard let locale = await bestLocale() else {
            throw RecordingError.localeNotSupported
        }
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        if let installationRequest = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            state = .downloadingModel
            try await installationRequest.downloadAndInstall()
        }
        return transcriber
    }

    private func bestLocale() async -> Locale? {
        let supported = await SpeechTranscriber.supportedLocales
        let current = Locale.current
        if let exact = supported.first(where: { $0.identifier(.bcp47) == current.identifier(.bcp47) }) {
            return exact
        }
        if let sameLanguage = supported.first(where: { $0.language.languageCode == current.language.languageCode }) {
            return sameLanguage
        }
        return supported.first(where: { $0.identifier(.bcp47) == "en-US" }) ?? supported.first
    }

    private func startResultsTask(
        for transcriber: SpeechTranscriber,
        checkpointing journal: RecordingJournal?
    ) {
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let text = self.formattedTranscriptionChunk(
                        String(result.text.characters),
                        range: result.range
                    )
                    if result.isFinal {
                        self.finalizedText += text
                        self.volatileText = ""
                        if !text.isEmpty {
                            self.lastFinalizedResultEnd = CMTimeRangeGetEnd(result.range)
                        }
                        try? journal?.saveCheckpoint(self.finalizedText)
                    } else {
                        self.volatileText = text
                    }
                }
            } catch {
                guard let self else { return }
                self.analysisFailure = error
                if self.state == .recording {
                    Task { @MainActor [weak self] in
                        await self?.stopRecording(
                            notice: "Live transcription stopped unexpectedly. The temporary audio was preserved for recovery."
                        )
                    }
                }
            }
        }
    }

    private func startAudioEngine(analyzerFormat: AVAudioFormat) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            do {
                let converted = try self.converter.convertBuffer(buffer, to: analyzerFormat)
                self.journalWriter?.append(converted)
                self.inputBuilder?.yield(AnalyzerInput(buffer: converted))
            } catch {
                // The audio journal makes later recovery possible if isolated
                // conversion failures occur, so don't terminate on one buffer.
            }
        }
        tapInstalled = true
        audioEngine.prepare()
        try audioEngine.start()
    }

    // MARK: - Stop and interruptions

    private func stopRecording(notice: String? = nil) async {
        guard state == .recording else { return }
        state = .stopping

        stopAudioEngine()

        var writerFailure: Error?
        if let journalWriter {
            do {
                try await journalWriter.finish()
            } catch {
                writerFailure = error
            }
        }
        self.journalWriter = nil

        inputBuilder?.finish()
        var finalizeFailure: Error?
        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            finalizeFailure = error
        }
        await resultsTask?.value

        let text = (finalizedText + volatileText).trimmingCharacters(in: .whitespacesAndNewlines)
        let currentJournal = journal
        if !text.isEmpty {
            try? currentJournal?.saveCheckpoint(text)
        }

        let needsRecovery = analysisFailure != nil || finalizeFailure != nil
        resetAnalysisPipeline()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        journal = nil

        if needsRecovery, let currentJournal, !currentJournal.audioSegmentURLs().isEmpty {
            errorMessage = notice ?? "The recording ended unexpectedly. Its temporary audio is preserved and will be recovered the next time Record opens."
            state = .idle
            return
        }

        if text.isEmpty {
            if let currentJournal, !currentJournal.audioSegmentURLs().isEmpty {
                errorMessage = "No live transcript was produced. The temporary audio is preserved for recovery the next time Record opens."
            } else {
                try? currentJournal?.remove()
                errorMessage = "No speech was detected, so no transcript was saved."
            }
            state = .idle
            return
        }

        do {
            lastSavedTranscript = try TranscriptStore.save(text, date: currentJournal?.startedAt ?? .now)
            try currentJournal?.remove()
            if let writerFailure {
                errorMessage = "The transcript was saved, but part of the temporary recovery audio could not be written. \(writerFailure.localizedDescription)"
            } else if let notice {
                errorMessage = notice
            }
        } catch {
            errorMessage = "Could not save the transcript. Temporary recovery data was kept. \(error.localizedDescription)"
        }

        state = .idle
    }

    private func handleAudioInterruption(_ notification: Notification) async {
        guard
            state == .recording,
            let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            AVAudioSession.InterruptionType(rawValue: typeValue) == .began
        else {
            return
        }
        await stopRecording(
            notice: "Recording was interrupted by the system. Everything captured before the interruption was saved."
        )
    }

    private func handleEngineConfigurationChange() async {
        guard state == .recording else { return }
        await stopRecording(
            notice: "Recording stopped safely because the microphone or audio route changed. Everything captured before the change was saved."
        )
    }

    private func handleJournalWriteFailure(_ error: Error) async {
        guard state == .recording else { return }
        await stopRecording(
            notice: "Recording stopped because temporary recovery audio could not be saved. The live transcript was saved if available. \(error.localizedDescription)"
        )
    }

    private func stopAudioEngine() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
    }

    private func abortPipeline(removeEmptyJournal: Bool) async {
        stopAudioEngine()
        if let journalWriter {
            try? await journalWriter.finish()
        }
        self.journalWriter = nil
        inputBuilder?.finish()
        resultsTask?.cancel()
        resetAnalysisPipeline()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        if removeEmptyJournal, let journal, journal.audioSegmentURLs().isEmpty {
            try? journal.remove()
        }
        journal = nil
    }

    private func resetAnalysisPipeline() {
        inputBuilder = nil
        resultsTask?.cancel()
        resultsTask = nil
        analyzer = nil
        transcriber = nil
        converter.reset()
        analysisFailure = nil
        lastFinalizedResultEnd = nil
    }

    // MARK: - Paragraph formatting

    /// SpeechTranscriber returns recognition chunks rather than semantic
    /// paragraphs. Use timing, punctuation, and paragraph length to create
    /// stable, readable boundaries without requiring a second model.
    private func formattedTranscriptionChunk(_ text: String, range: CMTimeRange) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard !finalizedText.isEmpty else { return trimmed }

        if shouldStartNewParagraph(for: range) {
            return "\n\n" + trimmed
        }

        let punctuationThatDoesNotNeedLeadingSpace = CharacterSet(charactersIn: ".,!?;:%)]}…")
        if let firstScalar = trimmed.unicodeScalars.first,
           punctuationThatDoesNotNeedLeadingSpace.contains(firstScalar) {
            return trimmed
        }
        return " " + trimmed
    }

    private func shouldStartNewParagraph(for range: CMTimeRange) -> Bool {
        guard let lastFinalizedResultEnd else { return false }
        let pause = CMTimeGetSeconds(CMTimeSubtract(range.start, lastFinalizedResultEnd))
        guard pause.isFinite, pause >= 0 else { return false }

        if pause >= Self.strongParagraphPause {
            return true
        }

        let currentParagraphLength = finalizedText
            .components(separatedBy: "\n\n")
            .last?
            .count ?? 0
        return pause >= Self.contextualParagraphPause
            && currentParagraphLength >= Self.minimumContextualParagraphLength
            && finalizedText.trimmingCharacters(in: .whitespacesAndNewlines)
                .last
                .map { ".!?…".contains($0) } == true
    }

    // MARK: - Recovery

    private func transcribeAudio(in journal: RecordingJournal) async throws -> String {
        let transcriber = try await makeTranscriber()
        state = .recovering
        self.transcriber = transcriber
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw RecordingError.noAudioFormat
        }

        finalizedText = ""
        volatileText = ""
        analysisFailure = nil
        lastFinalizedResultEnd = nil
        converter.reset()
        startResultsTask(for: transcriber, checkpointing: nil)

        let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputBuilder = inputBuilder
        try await analyzer.start(inputSequence: inputSequence)

        var suppliedAudio = false
        for url in journal.audioSegmentURLs() {
            do {
                let file = try AVAudioFile(forReading: url)
                while file.framePosition < file.length {
                    let remaining = file.length - file.framePosition
                    let frameCount = AVAudioFrameCount(min(8_192, remaining))
                    guard let buffer = AVAudioPCMBuffer(
                        pcmFormat: file.processingFormat,
                        frameCapacity: frameCount
                    ) else {
                        throw RecordingError.failedToReadRecoveryAudio
                    }
                    try file.read(into: buffer, frameCount: frameCount)
                    guard buffer.frameLength > 0 else { break }
                    let converted = try converter.convertBuffer(buffer, to: analyzerFormat)
                    inputBuilder.yield(AnalyzerInput(buffer: converted))
                    suppliedAudio = true
                }
            } catch {
                // A process kill can leave the final segment incomplete. Continue
                // with every earlier, finalized segment and the text checkpoint.
                continue
            }
        }

        guard suppliedAudio else {
            inputBuilder.finish()
            throw RecordingError.failedToReadRecoveryAudio
        }

        inputBuilder.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        await resultsTask?.value
        if let analysisFailure {
            throw analysisFailure
        }
        return (finalizedText + volatileText).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum RecordingError: LocalizedError {
    case microphoneDenied
    case localeNotSupported
    case noAudioFormat
    case noRecoverableSpeech
    case failedToReadRecoveryAudio

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "Microphone access is denied. Enable it in Settings > Privacy & Security > Microphone."
        case .localeNotSupported:
            return "On-device transcription doesn't support any available language on this device."
        case .noAudioFormat:
            return "Couldn't determine a compatible audio format for transcription."
        case .noRecoverableSpeech:
            return "No speech could be recovered from the interrupted recording."
        case .failedToReadRecoveryAudio:
            return "The temporary recovery audio could not be read."
        }
    }
}
