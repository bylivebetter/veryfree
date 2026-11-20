//
//  SessionMixer.swift
//  Speakin
//
//  Puts the system audio and the microphone on one timeline. Each source is placed by the host time
//  its audio was captured at, so the two stay in step however their devices are clocked, and either
//  one can drop out — a headset reconnecting, a device switching modes — without moving the other.
//  The file is written from this timeline, so it runs at wall-clock speed whatever the hardware does.
//

@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import Synchronization

nonisolated final class SessionMixer: @unchecked Sendable {
    static let sampleRate: Double = 48_000
    static let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!

    enum Slot: Int { case system = 0, microphone = 1 }

    private let lock = NSLock()
    private let capacity: Int
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>
    /// Host-time nanoseconds of position 0.
    let startNanos: UInt64
    // Guarded by `lock`.
    private var taken: Int64 = 0          // everything before this has gone to the file
    private var furthest: Int64 = 0       // end of the latest audio mixed in
    private var closed = false
    private var lateFrames: Int64 = 0
    private var peaks: [Float] = [0, 0]

    /// `seconds` of audio can sit in the mixer before it must be taken.
    init(originHostTime: UInt64, seconds: Int = 10) {
        capacity = Int(Self.sampleRate) * seconds
        left = .allocate(capacity: capacity)
        right = .allocate(capacity: capacity)
        left.initialize(repeating: 0, count: capacity)
        right.initialize(repeating: 0, count: capacity)
        startNanos = AudioConvertHostTimeToNanos(originHostTime)
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }

    // MARK: - Time

    /// Where on the timeline audio captured at `hostTime` belongs.
    func position(ofHostTime hostTime: UInt64) -> Int64 {
        let nanos = Int64(bitPattern: AudioConvertHostTimeToNanos(hostTime) &- startNanos)
        return Int64((Double(nanos) * Self.sampleRate / 1_000_000_000).rounded())
    }

    var now: Int64 { position(ofHostTime: AudioGetCurrentHostTime()) }

    /// The end of the latest audio mixed in.
    var end: Int64 { lock.withLock { furthest } }

    // MARK: - Mixing

    /// Adds `buffer` (48 kHz; mono goes to both channels) at `position`. Audio that arrives after its
    /// place has already been written is dropped; so is anything after the mixer was closed.
    func mix(_ buffer: AVAudioPCMBuffer, at position: Int64, slot: Slot, peak: Float) {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let channels = buffer.floatChannelData else { return }
        let sourceLeft = channels[0]
        let sourceRight = buffer.format.channelCount > 1 ? channels[1] : channels[0]

        lock.withLock {
            guard !closed else { return }
            peaks[slot.rawValue] = max(peaks[slot.rawValue], peak)
            var start = position
            var offset = 0
            var count = frames
            if start < taken {
                let late = Int(min(Int64(count), taken - start))
                lateFrames += Int64(late)
                offset += late
                count -= late
                start = taken
            }
            count = min(count, Int(taken + Int64(capacity) - start))
            guard count > 0 else { return }
            for i in 0..<count {
                let index = Int((start + Int64(i)) % Int64(capacity))
                left[index] += sourceLeft[offset + i]
                right[index] += sourceRight[offset + i]
            }
            furthest = max(furthest, start + Int64(count))
        }
    }

    /// Removes everything before `target` from the timeline and returns it, with silence wherever
    /// nothing was captured. Nil when there is nothing new.
    func take(upTo target: Int64) -> AVAudioPCMBuffer? {
        lock.withLock {
            let end = min(target, taken + Int64(capacity))
            guard end > taken,
                  let out = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: AVAudioFrameCount(end - taken)),
                  let channels = out.floatChannelData else { return nil }
            let count = Int(end - taken)
            out.frameLength = AVAudioFrameCount(count)
            var copied = 0
            while copied < count {
                let index = Int((taken + Int64(copied)) % Int64(capacity))
                let run = min(count - copied, capacity - index)
                for (ring, destination) in [(left, channels[0]), (right, channels[1])] {
                    // Two sources can add up past full scale; clip rather than wrap.
                    for i in 0..<run { destination[copied + i] = max(-1, min(1, ring[index + i])) }
                    (ring + index).update(repeating: 0, count: run)
                }
                copied += run
            }
            taken = end
            return out
        }
    }

    /// Peak levels (0...1) of each source since the last call.
    func takePeaks() -> (system: Float, microphone: Float) {
        lock.withLock {
            defer { peaks = [0, 0] }
            return (peaks[0], peaks[1])
        }
    }

    var droppedLateFrames: Int64 { lock.withLock { lateFrames } }

    /// No more audio is accepted after this.
    func close() {
        lock.withLock { closed = true }
    }
}

/// One source feeding the mixer. Runs on its capture's IOProc queue: converts what the device delivers
/// to the mixer's format and keeps it continuous, resyncing to the host clock when it drifts too far or
/// comes back after a gap.
nonisolated final class MixerInput: @unchecked Sendable {
    /// How far a source may drift from the host clock before it is put back in place.
    private static let tolerance = Int64(SessionMixer.sampleRate * 0.02)

    let slot: SessionMixer.Slot
    let createdNanos: UInt64
    /// Host-time nanoseconds of the last delivery, and of the last delivery that was not pure silence.
    let lastDelivery = Atomic<UInt64>(0)
    let lastSound = Atomic<UInt64>(0)

    private let mixer: SessionMixer
    private let nativeFormat: AVAudioFormat
    private let converter: AudioFormatConverter?
    private var nextPosition: Int64?

    init?(slot: SessionMixer.Slot, sampleRate: Double, mixer: SessionMixer) {
        let channels: AVAudioChannelCount = slot == .system ? 2 : 1
        guard let native = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false)
        else { return nil }
        if sampleRate == SessionMixer.sampleRate {
            converter = nil
        } else {
            guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: SessionMixer.sampleRate,
                                             channels: channels, interleaved: false),
                  let converter = AudioFormatConverter(from: native, to: target) else { return nil }
            self.converter = converter
        }
        self.slot = slot
        self.mixer = mixer
        nativeFormat = native
        createdNanos = AudioConvertHostTimeToNanos(AudioGetCurrentHostTime())
    }

    /// True if nothing has arrived for `seconds` — the device stopped without saying so.
    func isStalled(nowNanos: UInt64, after seconds: Double) -> Bool {
        let last = max(lastDelivery.load(ordering: .relaxed), createdNanos)
        return nowNanos > last && Double(nowNanos - last) / 1e9 > seconds
    }

    /// Seconds since anything but exact silence came in. Real microphones always hiss a little; only a
    /// muted or blocked one delivers zeros.
    func secondsSinceSound(nowNanos: UInt64) -> Double {
        let last = max(lastSound.load(ordering: .relaxed), createdNanos)
        return nowNanos > last ? Double(nowNanos - last) / 1e9 : 0
    }

    var hasHeardSound: Bool { lastSound.load(ordering: .relaxed) != 0 }

    /// One IOProc buffer: interleaved Float32, any channel count.
    func push(_ stream: AudioBuffer, hostTime: UInt64) {
        let nowNanos = AudioConvertHostTimeToNanos(AudioGetCurrentHostTime())
        lastDelivery.store(nowNanos, ordering: .relaxed)
        let channels = Int(stream.mNumberChannels)
        guard channels > 0, let samples = stream.mData?.assumingMemoryBound(to: Float.self) else { return }
        let frames = Int(stream.mDataByteSize) / (MemoryLayout<Float>.size * channels)
        guard frames > 0,
              let native = AVAudioPCMBuffer(pcmFormat: nativeFormat, frameCapacity: AVAudioFrameCount(frames)),
              let out = native.floatChannelData else { return }
        native.frameLength = AVAudioFrameCount(frames)

        var peak: Float = 0
        switch slot {
        case .system:
            for i in 0..<frames {
                let l = samples[i * channels]
                let r = channels > 1 ? samples[i * channels + 1] : l
                out[0][i] = l
                out[1][i] = r
                peak = max(peak, abs(l), abs(r))
            }
        case .microphone:
            let scale = 1 / Float(channels)
            for i in 0..<frames {
                var sum: Float = 0
                for c in 0..<channels { sum += samples[i * channels + c] }
                out[0][i] = sum * scale
                peak = max(peak, abs(out[0][i]))
            }
        }
        if peak > 0 { lastSound.store(nowNanos, ordering: .relaxed) }

        let converted: AVAudioPCMBuffer
        if let converter {
            // The resampler may hold a few frames back; they come out with the next buffer.
            guard let output = converter.convert(native) else { return }
            converted = output
        } else {
            converted = native
        }

        let captured = hostTime != 0 ? mixer.position(ofHostTime: hostTime) : nil
        var position = nextPosition ?? captured ?? mixer.now
        if let captured, abs(captured - position) > Self.tolerance {
            position = captured
        }
        nextPosition = position + Int64(converted.frameLength)
        mixer.mix(converted, at: position, slot: slot, peak: peak)
    }
}
