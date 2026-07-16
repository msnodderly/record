import Foundation

/// A finalized recognition chunk with its position on the analyzer timeline.
///
/// The journal's CAF segments are sequential and gapless, so chunk times and
/// times measured over the concatenated journal audio share the same clock.
struct TimedTranscriptChunk: Sendable, Equatable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
    let startsNewParagraph: Bool
}

/// A diarized span of audio attributed to one speaker.
struct SpeakerSegment: Sendable, Equatable {
    let speakerID: String
    let start: TimeInterval
    let end: TimeInterval
}

/// A run of consecutive paragraphs spoken by one speaker.
/// `speakerLabel` is nil when the transcript is not speaker-labeled.
struct SpeakerTurn: Sendable, Equatable {
    var speakerLabel: Int?
    var paragraphs: [String]
}

/// Pure composition of timed chunks and diarization segments into
/// speaker-attributed, paragraph-structured text. No I/O.
enum TranscriptComposer {
    private static let minimumTalkTimeFraction = 0.05
    private static let minimumTalkTimeSeconds: TimeInterval = 10

    /// Attributes each chunk to the diarized speaker it overlaps most, then
    /// groups chunks into turns and paragraphs.
    ///
    /// Speakers below both talk-time thresholds are treated as noise. When
    /// fewer than two qualified speakers remain, the transcript is returned
    /// as a single unlabeled stream so single-speaker recordings stay clean.
    static func attributeSpeakers(
        chunks: [TimedTranscriptChunk],
        segments: [SpeakerSegment]
    ) -> [SpeakerTurn] {
        guard !chunks.isEmpty else { return [] }

        let qualified = qualifiedSpeakerLabels(in: segments)
        guard qualified.count >= 2 else {
            return unlabeledTurns(from: chunks)
        }

        var previousLabel = qualified.values.min() ?? 1
        var turns: [SpeakerTurn] = []
        for chunk in chunks {
            let label = speakerLabel(
                for: chunk,
                segments: segments,
                qualified: qualified
            ) ?? previousLabel
            previousLabel = label

            if var current = turns.last, current.speakerLabel == label {
                if chunk.startsNewParagraph || current.paragraphs.isEmpty {
                    current.paragraphs.append(chunk.text)
                } else {
                    let joined = joinChunk(chunk.text, onto: current.paragraphs.removeLast())
                    current.paragraphs.append(joined)
                }
                turns[turns.count - 1] = current
            } else {
                turns.append(SpeakerTurn(speakerLabel: label, paragraphs: [chunk.text]))
            }
        }
        return turns
    }

    /// Fallback when timed chunks are unavailable (for example when a recovery
    /// checkpoint won over re-transcription): existing paragraphs, no labels.
    static func paragraphs(fromRawText text: String) -> [SpeakerTurn] {
        let paragraphs = text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !paragraphs.isEmpty else { return [] }
        return [SpeakerTurn(speakerLabel: nil, paragraphs: paragraphs)]
    }

    /// Renders turns back to transcript text, prefixing paragraphs with
    /// "Speaker N:" only when the turn carries a label.
    static func renderBody(_ turns: [SpeakerTurn]) -> String {
        turns.flatMap { turn -> [String] in
            guard let label = turn.speakerLabel else { return turn.paragraphs }
            guard let first = turn.paragraphs.first else { return [] }
            return ["Speaker \(label): \(first)"] + turn.paragraphs.dropFirst()
        }
        .joined(separator: "\n\n")
    }

    // MARK: - Attribution

    private static func qualifiedSpeakerLabels(in segments: [SpeakerSegment]) -> [String: Int] {
        var talkTime: [String: TimeInterval] = [:]
        for segment in segments {
            talkTime[segment.speakerID, default: 0] += max(0, segment.end - segment.start)
        }
        let total = talkTime.values.reduce(0, +)
        guard total > 0 else { return [:] }

        let qualifiedIDs = talkTime.filter {
            $0.value >= total * minimumTalkTimeFraction && $0.value >= minimumTalkTimeSeconds
        }.keys

        // Number speakers by order of first appearance in the recording.
        var labels: [String: Int] = [:]
        var next = 1
        for segment in segments where qualifiedIDs.contains(segment.speakerID) {
            if labels[segment.speakerID] == nil {
                labels[segment.speakerID] = next
                next += 1
            }
        }
        return labels
    }

    private static func speakerLabel(
        for chunk: TimedTranscriptChunk,
        segments: [SpeakerSegment],
        qualified: [String: Int]
    ) -> Int? {
        var overlap: [String: TimeInterval] = [:]
        for segment in segments where qualified[segment.speakerID] != nil {
            let amount = min(chunk.end, segment.end) - max(chunk.start, segment.start)
            if amount > 0 {
                overlap[segment.speakerID, default: 0] += amount
            }
        }
        let best = overlap.max { lhs, rhs in
            (lhs.value, rhs.key) < (rhs.value, lhs.key)
        }
        return best.flatMap { qualified[$0.key] }
    }

    private static func unlabeledTurns(from chunks: [TimedTranscriptChunk]) -> [SpeakerTurn] {
        var paragraphs: [String] = []
        for chunk in chunks {
            if chunk.startsNewParagraph || paragraphs.isEmpty {
                paragraphs.append(chunk.text)
            } else {
                paragraphs.append(joinChunk(chunk.text, onto: paragraphs.removeLast()))
            }
        }
        return [SpeakerTurn(speakerLabel: nil, paragraphs: paragraphs)]
    }

    /// Matches the live formatter's joining rule: no space before closing
    /// punctuation, a single space otherwise.
    private static func joinChunk(_ text: String, onto paragraph: String) -> String {
        let noLeadingSpace = CharacterSet(charactersIn: ".,!?;:%)]}…")
        if let first = text.unicodeScalars.first, noLeadingSpace.contains(first) {
            return paragraph + text
        }
        return paragraph + " " + text
    }
}
