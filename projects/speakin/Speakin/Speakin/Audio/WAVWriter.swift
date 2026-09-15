//
//  WAVWriter.swift
//  Speakin
//
//  Crash-safe 16-bit PCM WAV writer. Every appended buffer is handed to the OS immediately, so a
//  process crash mid-speech loses nothing but the header sizes — which `repairHeader` restores.
//

import AVFoundation

nonisolated final class WAVWriter {
    static let headerSize = 44

    let url: URL
    let sampleRate: Double
    let channels: Int
    private let handle: FileHandle
    private(set) var dataBytes: UInt64 = 0
    private var scratch: [Int16] = []
    private var closed = false

    init(url: URL, sampleRate: Double, channels: Int) throws {
        self.url = url
        self.sampleRate = sampleRate
        self.channels = channels
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Self.header(sampleRate: sampleRate, channels: channels, dataBytes: 0))
    }

    /// Seconds of audio written so far.
    var duration: TimeInterval {
        Double(dataBytes) / (sampleRate * Double(channels) * 2)
    }

    /// Appends a Float32 (interleaved or not) or Int16 buffer. Channel count must match.
    func append(_ buffer: AVAudioPCMBuffer) throws {
        precondition(!closed, "WAVWriter used after close")
        let frames = Int(buffer.frameLength)
        let ch = Int(buffer.format.channelCount)
        guard frames > 0, ch == channels else { return }

        scratch.removeAll(keepingCapacity: true)
        scratch.reserveCapacity(frames * ch)
        if let floats = buffer.floatChannelData {
            if buffer.format.isInterleaved {
                let p = floats[0]
                for i in 0..<(frames * ch) { scratch.append(Self.clamp(p[i])) }
            } else {
                for i in 0..<frames {
                    for c in 0..<ch { scratch.append(Self.clamp(floats[c][i])) }
                }
            }
        } else if let ints = buffer.int16ChannelData {
            if buffer.format.isInterleaved {
                let p = ints[0]
                for i in 0..<(frames * ch) { scratch.append(p[i]) }
            } else {
                for i in 0..<frames {
                    for c in 0..<ch { scratch.append(ints[c][i]) }
                }
            }
        } else {
            throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: "Unsupported PCM sample format"])
        }

        let data = scratch.withUnsafeBufferPointer { Data(buffer: $0) }
        try handle.write(contentsOf: data)
        dataBytes += UInt64(data.count)
    }

    /// Patches the header, flushes to disk and closes the file. Returns the recorded duration.
    @discardableResult
    func close() throws -> TimeInterval {
        guard !closed else { return duration }
        closed = true
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Self.header(sampleRate: sampleRate, channels: channels, dataBytes: dataBytes))
        try handle.synchronize()
        try handle.close()
        return duration
    }

    deinit {
        if !closed { _ = try? close() }
    }

    // MARK: - Header helpers

    private static func clamp(_ x: Float) -> Int16 {
        let v = max(-1, min(1, x))
        return Int16(v * 32767)
    }

    static func header(sampleRate: Double, channels: Int, dataBytes: UInt64) -> Data {
        let dataSize = UInt32(min(dataBytes, UInt64(UInt32.max) - 36))
        var d = Data(capacity: headerSize)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataSize)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(1)                                   // PCM
        u16(UInt16(channels))
        u32(UInt32(sampleRate))
        u32(UInt32(sampleRate) * UInt32(channels) * 2)
        u16(UInt16(channels * 2))
        u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataSize)
        return d
    }

    /// Rewrites the size fields of a WAV whose writer never got to close it.
    /// Returns true if the header had to be fixed.
    @discardableResult
    static func repairHeader(at url: URL) throws -> Bool {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        guard let head = try handle.read(upToCount: headerSize), head.count == headerSize else { return false }
        let fileSize = try handle.seekToEnd()
        let actualData = fileSize - UInt64(headerSize)

        func u32(_ offset: Int) -> UInt32 {
            head.subdata(in: offset..<(offset + 4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        }
        func u16(_ offset: Int) -> UInt16 {
            head.subdata(in: offset..<(offset + 2)).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.littleEndian
        }
        guard u32(40) != UInt32(min(actualData, UInt64(UInt32.max) - 36)) else { return false }
        let channels = Int(u16(22))
        let sampleRate = Double(u32(24))
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: header(sampleRate: sampleRate, channels: channels, dataBytes: actualData))
        try handle.synchronize()
        return true
    }
}
