import AVFoundation

/// Converts microphone buffers to the format SpeechAnalyzer expects.
final class BufferConverter {
    enum ConversionError: Error {
        case failedToCreateConverter
        case failedToCreateConversionBuffer
        case conversionFailed(NSError?)
    }

    private var converter: AVAudioConverter?

    func convertBuffer(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let inputFormat = buffer.format
        guard inputFormat != format else { return buffer }

        if converter == nil || converter?.inputFormat != inputFormat || converter?.outputFormat != format {
            converter = AVAudioConverter(from: inputFormat, to: format)
            converter?.primeMethod = .none // Prevents timestamp drift at the start of the stream.
        }
        guard let converter else {
            throw ConversionError.failedToCreateConverter
        }

        let sampleRateRatio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let scaledFrameLength = Double(buffer.frameLength) * sampleRateRatio
        let frameCapacity = AVAudioFrameCount(scaledFrameLength.rounded(.up))
        guard let conversionBuffer = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: frameCapacity) else {
            throw ConversionError.failedToCreateConversionBuffer
        }

        var error: NSError?
        var bufferProcessed = false
        let status = converter.convert(to: conversionBuffer, error: &error) { _, inputStatus in
            defer { bufferProcessed = true }
            inputStatus.pointee = bufferProcessed ? .noDataNow : .haveData
            return bufferProcessed ? nil : buffer
        }
        guard status != .error else {
            throw ConversionError.conversionFailed(error)
        }
        return conversionBuffer
    }

    func reset() {
        converter = nil
    }
}
