//
//  SessionWriter.swift
//  Speakin
//
//  Writes a long recording to a fragmented .m4a (AAC). Fragments are flushed every few seconds, so
//  if the app dies mid-call the file on disk is still a playable recording minus the last fragment.
//  Append and finish from one serial queue; the counters can be read from anywhere.
//

@preconcurrency import AVFoundation
import Foundation
import Synchronization
import os

nonisolated final class SessionWriter: @unchecked Sendable {
    let url: URL
    let format: AVAudioFormat
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let formatDescription: CMAudioFormatDescription
    private let framesWritten = Atomic<Int64>(0)
    private let droppedFrames = Atomic<Int64>(0)
    private var finished = false

    /// Seconds of audio written so far.
    var duration: TimeInterval { Double(framesWritten.load(ordering: .relaxed)) / format.sampleRate }
    /// Audio the AAC encoder could not keep up with (should stay 0).
    var dropped: TimeInterval { Double(droppedFrames.load(ordering: .relaxed)) / format.sampleRate }

    init(url: URL, format: AVAudioFormat, bitRate: Int = 128_000, fragmentSeconds: Double = 5) throws {
        self.url = url
        self.format = format
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        // A fragmented file stays playable if the process never gets to finish it.
        writer.movieFragmentInterval = CMTime(seconds: fragmentSeconds, preferredTimescale: 600)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVEncoderBitRateKey: bitRate,
        ]
        input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "Cannot write audio to \(url.lastPathComponent)"])
        }
        writer.add(input)

        var description: CMAudioFormatDescription?
        var asbd = format.streamDescription.pointee
        let status = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
                                                    layoutSize: 0, layout: nil, magicCookieSize: 0,
                                                    magicCookie: nil, extensions: nil, formatDescriptionOut: &description)
        guard status == noErr, let description else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Unsupported recording format"])
        }
        formatDescription = description

        guard writer.startWriting() else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
        writer.startSession(atSourceTime: .zero)
    }

    /// Appends PCM; never blocks on the encoder (audio it cannot take is counted as dropped).
    func append(_ buffer: AVAudioPCMBuffer) throws {
        guard !finished, buffer.frameLength > 0 else { return }
        if let error = writer.error { throw error }
        guard input.isReadyForMoreMediaData else {
            droppedFrames.add(Int64(buffer.frameLength), ordering: .relaxed)
            return
        }
        let time = CMTime(value: framesWritten.load(ordering: .relaxed), timescale: CMTimeScale(format.sampleRate))
        let sampleBuffer = try makeSampleBuffer(from: buffer, at: time)
        guard input.append(sampleBuffer) else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
        framesWritten.add(Int64(buffer.frameLength), ordering: .relaxed)
    }

    /// Flushes and closes the file. `completion` runs on a queue of AVFoundation's choosing.
    func finish(_ completion: @escaping @Sendable (Error?) -> Void) {
        guard !finished else { completion(nil); return }
        finished = true
        input.markAsFinished()
        writer.finishWriting { [self] in completion(writer.error) }
    }

    /// Abandons the file: nothing worth keeping was recorded.
    func cancel() {
        guard !finished else { return }
        finished = true
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: url)
    }

    private func makeSampleBuffer(from buffer: AVAudioPCMBuffer, at time: CMTime) throws -> CMSampleBuffer {
        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(format.sampleRate)),
                                        presentationTimeStamp: time,
                                        decodeTimeStamp: .invalid)
        var status = CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
                                          makeDataReadyCallback: nil, refcon: nil,
                                          formatDescription: formatDescription,
                                          sampleCount: CMItemCount(buffer.frameLength),
                                          sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                          sampleSizeEntryCount: 0, sampleSizeArray: nil,
                                          sampleBufferOut: &sampleBuffer)
        guard status == noErr, let sampleBuffer else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "CMSampleBufferCreate failed"])
        }
        status = CMSampleBufferSetDataBufferFromAudioBufferList(sampleBuffer, blockBufferAllocator: kCFAllocatorDefault,
                                                                blockBufferMemoryAllocator: kCFAllocatorDefault,
                                                                flags: 0, bufferList: buffer.audioBufferList)
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "CMSampleBufferSetDataBuffer failed"])
        }
        return sampleBuffer
    }
}
