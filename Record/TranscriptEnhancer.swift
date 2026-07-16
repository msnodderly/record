import AVFoundation
import FluidAudio
import FoundationModels
import Foundation
import os

/// Everything the enhancement pass needs, captured at the moment the raw
/// transcript was saved.
struct EnhancementInput: Sendable {
    let raw: Transcript
    let rawText: String
    let chunks: [TimedTranscriptChunk]
    let audioSegmentURLs: [URL]
    let scratchDirectory: URL?
    let recordedAt: Date
}

/// Best-effort post-processing of a saved transcript: speaker diarization,
/// LLM text cleanup, and generated title/summary/tags.
///
/// The raw transcript is already durable before this runs. Every stage
/// degrades independently — no speaker labels, uncleaned text, or a
/// date-based filename — and a total failure leaves the raw file untouched.
final class TranscriptEnhancer: Sendable {
    private static let logger = Logger(subsystem: "com.mds.Record", category: "TranscriptEnhancer")

    /// Token budget per cleanup batch. The ~4096-token context is shared by
    /// instructions, schema, and carried context (~200 together), the input
    /// batch, AND the generated output — which for a 1:1 cleanup is about the
    /// size of the input. That caps input at ~1950 tokens; budgeting 1500
    /// leaves margin for the chars/4 estimate running hot and for output
    /// slightly exceeding input. Overflow is survivable (the batch is split
    /// and retried), just slow.
    private static let cleanupBatchTokenBudget = 1500
    private static let carriedContextLength = 200
    private static let metadataSampleLength = 1500
    private static let preambleSkipSeconds: TimeInterval = 30

    /// Runs the pass. `afterAudioConsumed` is invoked as soon as the journal
    /// audio is no longer needed — after diarization finishes, fails, or is
    /// skipped — so the caller can delete the journal without waiting for the
    /// text stages. Returns the enhanced transcript, or nil if the raw file
    /// should remain as saved.
    func enhance(
        _ input: EnhancementInput,
        afterAudioConsumed: @Sendable () -> Void,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async -> Transcript? {
        var segments: [SpeakerSegment]?
        do {
            segments = try await diarize(input, progress: progress)
            Self.logger.notice("Diarization produced \(segments?.count ?? -1, privacy: .public) segments")
            if let segments {
                let talkTimes = Dictionary(grouping: segments, by: \.speakerID)
                    .mapValues { $0.reduce(0) { $0 + ($1.end - $1.start) } }
                    .map { "\($0.key): \(Int($0.value))s" }
                    .sorted()
                    .joined(separator: ", ")
                Self.logger.notice("Speaker talk times: [\(talkTimes, privacy: .public)]")
            }
        } catch {
            Self.logger.error("Diarization skipped: \(error.localizedDescription, privacy: .public)")
            segments = nil
        }
        afterAudioConsumed()
        guard !Task.isCancelled else {
            Self.logger.notice("Enhancement cancelled after diarization stage")
            return nil
        }

        var turns: [SpeakerTurn]
        if let segments, !input.chunks.isEmpty {
            turns = TranscriptComposer.attributeSpeakers(chunks: input.chunks, segments: segments)
        } else if !input.chunks.isEmpty {
            turns = TranscriptComposer.attributeSpeakers(chunks: input.chunks, segments: [])
        } else {
            turns = TranscriptComposer.paragraphs(fromRawText: input.rawText)
        }
        guard !turns.isEmpty else { return nil }
        Self.logger.notice("Composed \(turns.count, privacy: .public) turns, labeled: \(turns.contains { $0.speakerLabel != nil }, privacy: .public)")
        guard !Task.isCancelled else { return finalize(input, turns: turns, metadata: nil) }

        let acousticallyLabeled = turns.contains { $0.speakerLabel != nil }
        turns = await cleanUp(turns: turns)
        guard !Task.isCancelled else {
            Self.logger.notice("Enhancement cancelled after cleanup stage")
            return finalize(input, turns: turns, metadata: nil)
        }

        if !acousticallyLabeled {
            turns = await inferSpeakerLabels(turns: turns)
            guard !Task.isCancelled else {
                return finalize(input, turns: turns, metadata: nil)
            }
        }

        let metadata = await generateMetadata(for: turns, chunks: input.chunks)
        return finalize(input, turns: turns, metadata: metadata)
    }

    // MARK: - Stage A: diarization

    private func diarize(
        _ input: EnhancementInput,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> [SpeakerSegment]? {
        guard !input.audioSegmentURLs.isEmpty, !input.chunks.isEmpty else { return nil }

        let audioURL: URL
        if input.audioSegmentURLs.count == 1 {
            audioURL = input.audioSegmentURLs[0]
        } else {
            guard let scratchDirectory = input.scratchDirectory else { return nil }
            audioURL = try concatenateSegments(input.audioSegmentURLs, in: scratchDirectory)
        }

        let manager = OfflineDiarizerManager(config: OfflineDiarizerConfig())
        try await manager.prepareModels()
        let result = try await manager.process(audioURL) { done, total in
            guard total > 0 else { return }
            progress?(Double(done) / Double(total))
        }
        return result.segments.map {
            SpeakerSegment(
                speakerID: $0.speakerId,
                start: TimeInterval($0.startTimeSeconds),
                end: TimeInterval($0.endTimeSeconds)
            )
        }
    }

    /// The diarizer takes a single file; journal segments are sequential and
    /// gapless, so streaming them into one CAF preserves the analyzer
    /// timeline the chunks were measured on. The scratch file transiently
    /// doubles the journal's disk footprint and is removed with the journal.
    private func concatenateSegments(_ urls: [URL], in scratchDirectory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        let outputURL = scratchDirectory.appendingPathComponent("full.caf")

        var output: AVAudioFile?
        for url in urls {
            do {
                let file = try AVAudioFile(forReading: url)
                if output == nil {
                    output = try AVAudioFile(
                        forWriting: outputURL,
                        settings: file.processingFormat.settings,
                        commonFormat: file.processingFormat.commonFormat,
                        interleaved: file.processingFormat.isInterleaved
                    )
                }
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
                    try output?.write(from: buffer)
                }
            } catch {
                // A process kill can leave the final segment incomplete;
                // diarize everything before it, matching recovery behavior.
                continue
            }
        }
        guard output != nil else { throw RecordingError.failedToReadRecoveryAudio }
        return outputURL
    }

    // MARK: - Stage C: text cleanup

    /// Transcripts of ordinary speech routinely trip the default safety
    /// guardrails ("Detected content likely to be unsafe"). Apple's
    /// sanctioned fix for transforming user-authored content is the
    /// permissive-guardrails model — which only supports plain string
    /// responses, not @Generable guided generation, so both LLM stages
    /// use free-text prompting.
    private static let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)

    private static let cleanupInstructions = """
        You clean up raw speech-to-text transcripts of lectures, meetings, \
        and technical discussions. Fix punctuation and capitalization. \
        Speech recognizers often mishear words: when a word or phrase is \
        clearly wrong for its context, replace it with what the speaker most \
        likely said — for example, "Asians" in a software discussion is \
        almost certainly "agents", and "hardest engineering" is likely \
        "harness engineering". Prefer domain-appropriate technical terms. \
        Remove filler words and disfluencies such as "um", "uh", "you know", \
        and repeated words. Never summarize, drop sentences, or add new \
        content. Preserve blank-line paragraph breaks. Respond with only the \
        cleaned text, nothing else.
        """

    /// A single-task prompt labels far more reliably on the small on-device
    /// model than folding labeling into the cleanup instructions did.
    private static let labelingInstructions = """
        You add speaker labels to transcripts of conversations such as \
        interviews and podcasts. Work out from context where the speaker \
        changes. Return the text exactly as given, word for word, with \
        "Speaker 1: ", "Speaker 2: ", and so on inserted at the start of \
        each speaker's turn. Start a new paragraph wherever the speaker \
        changes mid-paragraph. Keep the numbering consistent with any labels \
        in the context. If the whole text is one person speaking, return it \
        exactly unchanged with no labels added.
        """

    /// Cleanup is transformation, not generation — sample near-greedily so
    /// identical input yields near-identical output.
    private static let cleanupOptions = GenerationOptions(temperature: 0.2)

    private func cleanUp(turns: [SpeakerTurn]) async -> [SpeakerTurn] {
        guard case .available = Self.model.availability else {
            Self.logger.notice("Cleanup skipped, model unavailable: \(String(describing: Self.model.availability), privacy: .public)")
            return turns
        }

        var carriedContext = ""
        var cleaned: [SpeakerTurn] = []
        var prewarmed = false
        for turn in turns {
            var cleanedParagraphs: [String] = []
            for batch in batches(of: turn.paragraphs) {
                if Task.isCancelled {
                    cleanedParagraphs.append(contentsOf: batch)
                    continue
                }
                let result = await cleanBatch(
                    batch,
                    carriedContext: carriedContext,
                    prewarm: !prewarmed,
                    allowSplit: true
                )
                prewarmed = true
                cleanedParagraphs.append(contentsOf: result)
                carriedContext = String(result.joined(separator: "\n\n").suffix(Self.carriedContextLength))
            }
            cleaned.append(SpeakerTurn(speakerLabel: turn.speakerLabel, paragraphs: cleanedParagraphs))
        }
        return cleaned
    }

    /// Packs consecutive paragraphs into batches within the token budget so
    /// hour-long transcripts need a dozen model calls instead of hundreds.
    private func batches(of paragraphs: [String]) -> [[String]] {
        var batches: [[String]] = []
        var current: [String] = []
        var currentTokens = 0
        for paragraph in paragraphs {
            let tokens = estimatedTokens(paragraph)
            if !current.isEmpty, currentTokens + tokens > Self.cleanupBatchTokenBudget {
                batches.append(current)
                current = []
                currentTokens = 0
            }
            current.append(paragraph)
            currentTokens += tokens
        }
        if !current.isEmpty {
            batches.append(current)
        }
        return batches
    }

    /// Roughly one token per four characters of English text. Conservative
    /// enough that a batch plus instructions and response stays well inside
    /// the model's fixed context window.
    private func estimatedTokens(_ text: String) -> Int {
        max(1, text.count / 4)
    }

    /// Fraction of output words that don't appear in the input — a cheap
    /// order-insensitive measure of how much the model actually edited,
    /// logged as evidence that cleanup is (or isn't) doing real work.
    private static func wordChangeRatio(from original: String, to revised: String) -> Double {
        guard original != revised else { return 0 }
        var counts: [Substring: Int] = [:]
        for word in original.split(whereSeparator: \.isWhitespace) {
            counts[word, default: 0] += 1
        }
        let revisedWords = revised.split(whereSeparator: \.isWhitespace)
        var unmatched = 0
        for word in revisedWords {
            if let count = counts[word], count > 0 {
                counts[word] = count - 1
            } else {
                unmatched += 1
            }
        }
        return Double(unmatched) / Double(max(revisedWords.count, 1))
    }

    /// Cleans one batch, returning paragraphs. Falls back to the raw batch on
    /// any error; a context overflow is retried once as two halves.
    private func cleanBatch(
        _ batch: [String],
        carriedContext: String,
        prewarm: Bool,
        allowSplit: Bool
    ) async -> [String] {
        let joined = batch.joined(separator: "\n\n")
        var prompt = ""
        if !carriedContext.isEmpty {
            prompt += "Context from the preceding transcript (do not repeat it in your answer):\n…\(carriedContext)\n\n"
        }
        prompt += "Clean up this transcript excerpt:\n\n\(joined)"

        // A fresh session per batch: sessions accumulate their transcript,
        // and reuse would overflow the fixed context window.
        let session = LanguageModelSession(model: Self.model, instructions: Self.cleanupInstructions)
        if prewarm {
            session.prewarm()
        }

        do {
            let response = try await session.respond(to: prompt, options: Self.cleanupOptions)
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            // A wildly different length means the model summarized or padded.
            guard text.count >= joined.count * 2 / 5, text.count <= joined.count * 5 / 2 else {
                Self.logger.notice("Cleanup batch rejected: \(joined.count, privacy: .public) chars in, \(text.count, privacy: .public) out")
                return batch
            }
            Self.logger.notice("Cleanup batch: \(joined.count, privacy: .public) chars in, \(text.count, privacy: .public) out, ~\(Int(Self.wordChangeRatio(from: joined, to: text) * 100), privacy: .public)% words changed")
            let paragraphs = text
                .components(separatedBy: "\n\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return paragraphs.isEmpty ? batch : paragraphs
        } catch let error as LanguageModelSession.GenerationError {
            if case .exceededContextWindowSize = error, allowSplit, batch.count > 1 {
                let midpoint = batch.count / 2
                let first = await cleanBatch(
                    Array(batch[..<midpoint]),
                    carriedContext: carriedContext,
                    prewarm: false,
                    allowSplit: false
                )
                let second = await cleanBatch(
                    Array(batch[midpoint...]),
                    carriedContext: "",
                    prewarm: false,
                    allowSplit: false
                )
                return first + second
            }
            Self.logger.notice("Cleanup batch kept raw: \(error.localizedDescription)")
            return batch
        } catch {
            Self.logger.notice("Cleanup batch kept raw: \(error.localizedDescription)")
            return batch
        }
    }

    // MARK: - Stage C2: text-based speaker labeling

    /// Fallback when acoustic diarization heard a single voice: let the model
    /// infer speaker turns from conversational context. Labels are inserted
    /// as literal text; a batch is rejected outright if the model changed
    /// the words rather than only inserting labels.
    private func inferSpeakerLabels(turns: [SpeakerTurn]) async -> [SpeakerTurn] {
        guard case .available = Self.model.availability else { return turns }

        let paragraphs = turns.flatMap(\.paragraphs)
        guard !paragraphs.isEmpty else { return turns }

        var labeled: [String] = []
        var carriedContext = ""
        for batch in batches(of: paragraphs) {
            if Task.isCancelled {
                labeled.append(contentsOf: batch)
                continue
            }
            let joined = batch.joined(separator: "\n\n")
            var prompt = ""
            if !carriedContext.isEmpty {
                prompt += "Labeled context from the preceding transcript (do not repeat it):\n…\(carriedContext)\n\n"
            }
            prompt += "Add speaker labels to this transcript excerpt:\n\n\(joined)"

            let session = LanguageModelSession(model: Self.model, instructions: Self.labelingInstructions)
            do {
                let response = try await session.respond(to: prompt, options: Self.cleanupOptions)
                let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                let withoutLabels = text.replacingOccurrences(
                    of: #"Speaker \d+:\s*"#,
                    with: "",
                    options: .regularExpression
                )
                if Self.wordChangeRatio(from: joined, to: withoutLabels) <= 0.05 {
                    labeled.append(contentsOf: text
                        .components(separatedBy: "\n\n")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty })
                } else {
                    Self.logger.notice("Speaker inference batch rejected: model rewrote the text")
                    labeled.append(contentsOf: batch)
                }
            } catch {
                Self.logger.notice("Speaker inference batch kept unlabeled: \(error.localizedDescription, privacy: .public)")
                labeled.append(contentsOf: batch)
            }
            carriedContext = String(labeled.joined(separator: "\n\n").suffix(Self.carriedContextLength))
        }

        let didLabel = labeled.contains { $0.hasPrefix("Speaker ") }
        Self.logger.notice("Speaker inference labeled: \(didLabel, privacy: .public)")
        return [SpeakerTurn(speakerLabel: nil, paragraphs: labeled)]
    }

    // MARK: - Stage D: title

    private func generateMetadata(
        for turns: [SpeakerTurn],
        chunks: [TimedTranscriptChunk]
    ) async -> String? {
        guard case .available = Self.model.availability else {
            Self.logger.notice("Title skipped, model unavailable: \(String(describing: Self.model.availability), privacy: .public)")
            return nil
        }

        let body = turns.flatMap(\.paragraphs).joined(separator: "\n\n")
        guard !body.isEmpty else { return nil }

        // Openings are dominated by housekeeping ("can everyone hear me"),
        // so sample from past the preamble plus the middle of the recording.
        let beginningOffset: Int
        if let firstSettled = chunks.first(where: { $0.start >= Self.preambleSkipSeconds }),
           let position = position(of: firstSettled.text, in: body) {
            beginningOffset = position
        } else {
            beginningOffset = min(400, max(0, body.count - Self.metadataSampleLength))
        }
        let beginning = sample(body, from: beginningOffset)
        let middle = sample(body, from: max(0, body.count / 2 - Self.metadataSampleLength / 2))

        let prompt = """
            Name this transcript of a recorded lecture or meeting, based on \
            these excerpts. Name the specific subject matter; avoid generic \
            titles such as "Meeting Recording", "Lecture", or "Discussion". \
            Respond with only the title: a 3 to 8 word noun phrase using \
            only letters, digits, spaces, and hyphens.

            Beginning:
            \(beginning)

            Middle:
            \(middle)
            """
        let session = LanguageModelSession(model: Self.model)
        do {
            let response = try await session.respond(to: prompt)
            // Free-text models pad despite instructions; keep the first
            // non-empty line and let sanitizedTitle handle the rest.
            let title = response.content
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'.“”")) }
                .first { !$0.isEmpty }
            return title
        } catch {
            Self.logger.notice("Metadata generation skipped: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func position(of chunkText: String, in body: String) -> Int? {
        // Cleanup may have reworded the chunk; match on its opening words.
        let prefix = String(chunkText.prefix(24))
        guard !prefix.isEmpty, let range = body.range(of: prefix) else { return nil }
        return body.distance(from: body.startIndex, to: range.lowerBound)
    }

    private func sample(_ text: String, from offset: Int) -> String {
        let start = text.index(text.startIndex, offsetBy: min(offset, text.count))
        return String(text[start...].prefix(Self.metadataSampleLength))
    }

    // MARK: - Stage E: persistence

    private func finalize(
        _ input: EnhancementInput,
        turns: [SpeakerTurn],
        metadata: String?
    ) -> Transcript? {
        let body = TranscriptComposer.renderBody(turns)
        guard !body.isEmpty else { return nil }

        // Without metadata and without speaker labels the enhanced document
        // would be byte-equivalent to the raw file; leave the raw file alone.
        let isLabeled = turns.contains { $0.speakerLabel != nil }
        if metadata == nil, !isLabeled, body == input.rawText {
            Self.logger.notice("Nothing to persist: no labels, no title, text unchanged")
            return nil
        }

        do {
            return try TranscriptStore.finalizeEnhanced(
                raw: input.raw,
                body: body,
                title: metadata,
                recordedAt: input.recordedAt
            )
        } catch {
            Self.logger.error("Enhanced transcript could not be written: \(error.localizedDescription)")
            return nil
        }
    }
}
