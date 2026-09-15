//
//  AudioFormatConverter.swift
//  Speakin
//
//  Streaming sample-rate / channel / sample-format converter around AVAudioConverter.
//  Keeps resampler state between calls so consecutive buffers stay continuous.
//  Not thread-safe: feed it from one thread at a time.
//

@preconcurrency import AVFoundation

nonisolated final class AudioFormatConverter {
    let inputFormat: AVAudioFormat
    let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter

    init?(from inputFormat: AVAudioFormat, to outputFormat: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else { return nil }
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.converter = converter
    }

    /// Converts one buffer. Returns nil on failure or when nothing came out (the resampler
    /// may hold a few frames back; they are emitted with the next call).
    func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }

        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return input
        }
        if status == .error { return nil }
        return output.frameLength > 0 ? output : nil
    }
}

extension AVAudioPCMBuffer {
    /// Deep copy of the audible frames, so a buffer handed to us by an engine tap can outlive the callback.
    nonisolated func speakin_copy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(frameLength, 1)) else { return nil }
        copy.frameLength = frameLength
        let source = UnsafeMutableAudioBufferListPointer(mutableAudioBufferList)
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(source, target) {
            guard let src = from.mData, let dst = to.mData else { continue }
            memcpy(dst, src, Int(min(from.mDataByteSize, to.mDataByteSize)))
        }
        return copy
    }

    /// Root-mean-square level in 0...1 (Float32 or Int16 buffers).
    nonisolated var speakin_rmsLevel: Float {
        let frames = Int(frameLength)
        guard frames > 0 else { return 0 }
        if let data = floatChannelData {
            var sum: Float = 0
            let channel = data[0]
            for i in 0..<frames { sum += channel[i] * channel[i] }
            return min(1, (sum / Float(frames)).squareRoot())
        }
        if let data = int16ChannelData {
            var sum: Float = 0
            let channel = data[0]
            for i in 0..<frames {
                let v = Float(channel[i]) / 32768
                sum += v * v
            }
            return min(1, (sum / Float(frames)).squareRoot())
        }
        return 0
    }
}
