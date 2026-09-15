//
//  AudioRecorder.swift
//  Speakin
//
//  Microphone capture. Every buffer is converted to 16 kHz mono, appended to a WAV on disk and
//  handed to the caller — in that order, so the file is always at least as complete as anything
//  the transcriber has seen.
//

@preconcurrency import AVFoundation
import Foundation
import os

nonisolated enum AudioRecorderError: LocalizedError {
    case microphoneDenied
    case noInputDevice

    var errorDescription: String? {
        switch self {
        case .microphoneDenied: "Microphone access is denied. Allow Speakin in System Settings → Privacy & Security → Microphone."
        case .noInputDevice: "No microphone is available."
        }
    }
}

nonisolated final class AudioRecorder: @unchecked Sendable {
    static let canonicalFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: 16_000,
                                               channels: 1,
                                               interleaved: false)!

    struct Callbacks: Sendable {
        /// Converted (16 kHz mono Float32) audio, already written to disk. Called on a serial queue.
        var onBuffer: @Sendable (AVAudioPCMBuffer) -> Void
        /// RMS level 0...1 per buffer. Called on a serial queue.
        var onLevel: @Sendable (Float) -> Void
        /// The engine stopped on its own (input device changed / unplugged).
        var onInterruption: @Sendable () -> Void
    }

    /// Everything the tap touches lives here, so a callback still in flight during `stop()` never
    /// races with the next session.
    private final class Session: @unchecked Sendable {
        let writer: WAVWriter
        let callbacks: Callbacks
        let queue = DispatchQueue(label: "com.bylivebetter.speakin.recorder", qos: .userInitiated)
        private(set) var writeError: Error?
        private var closed = false
        // Only touched on the tap thread. Rebuilt whenever the hardware format changes.
        private var converter: AudioFormatConverter?

        init(writer: WAVWriter, callbacks: Callbacks) {
            self.writer = writer
            self.callbacks = callbacks
        }

        func handle(_ tapBuffer: AVAudioPCMBuffer) {
            // Audio thread: produce a buffer we own, then leave the thread quickly.
            let converted: AVAudioPCMBuffer?
            if tapBuffer.format == AudioRecorder.canonicalFormat {
                converted = tapBuffer.speakin_copy()
            } else {
                if converter?.inputFormat != tapBuffer.format {
                    converter = AudioFormatConverter(from: tapBuffer.format, to: AudioRecorder.canonicalFormat)
                }
                converted = converter?.convert(tapBuffer)
            }
            guard let converted else { return }
            queue.async { [self] in
                guard !closed else { return }
                do { try writer.append(converted) } catch { writeError = writeError ?? error }
                callbacks.onBuffer(converted)
                callbacks.onLevel(converted.speakin_rmsLevel)
            }
        }

        func close() throws -> TimeInterval {
            var result: Result<TimeInterval, Error> = .success(0)
            queue.sync {
                closed = true
                do {
                    let duration = try writer.close()
                    if let writeError { throw writeError }
                    result = .success(duration)
                } catch {
                    result = .failure(error)
                }
            }
            return try result.get()
        }
    }

    private let engine = AVAudioEngine()
    private var session: Session?
    private var configurationObserver: NSObjectProtocol?

    var isRecording: Bool { session != nil }

    static var microphoneAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func requestMicrophoneAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    static var currentInputDeviceName: String? {
        AVCaptureDevice.default(for: .audio)?.localizedName
    }

    /// Call from the main thread (as `stop()` and the configuration-change handler are).
    func start(writingTo url: URL, callbacks: Callbacks) throws {
        guard session == nil else { return }
        guard Self.microphoneAuthorized else { throw AudioRecorderError.microphoneDenied }

        let writer = try WAVWriter(url: url, sampleRate: Self.canonicalFormat.sampleRate, channels: 1)
        let session = Session(writer: writer, callbacks: callbacks)
        do {
            try installTapAndRun(for: session)
        } catch {
            _ = try? writer.close()
            try? FileManager.default.removeItem(at: url)
            throw error
        }

        self.session = session
        // The engine stops itself when the audio hardware reconfigures (a device is plugged in, another app
        // starts playing through a Bluetooth headset, …). Keep recording into the same file instead of ending
        // the speech.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    private func installTapAndRun(for session: Session) throws {
        let input = engine.inputNode
        let native = input.outputFormat(forBus: 0)
        guard native.sampleRate > 0, native.channelCount > 0 else { throw AudioRecorderError.noInputDevice }

        // format nil = whatever the hardware delivers; the session converts per buffer.
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, _ in
            session.handle(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        Log.audio.info("capturing \(native.sampleRate, format: .fixed(precision: 0)) Hz, \(native.channelCount) ch from \(Self.currentInputDeviceName ?? "unknown input", privacy: .public)")
    }

    private func handleConfigurationChange() {
        guard let session else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        do {
            try installTapAndRun(for: session)
            Log.audio.info("audio engine restarted after a configuration change; recording continues")
        } catch {
            Log.audio.error("audio engine could not restart after a configuration change: \(error.localizedDescription, privacy: .public)")
            session.callbacks.onInterruption()
        }
    }

    /// Stops capture and closes the file. Returns the recorded duration in seconds.
    @discardableResult
    func stop() throws -> TimeInterval {
        guard let session else { return 0 }
        self.session = nil
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        return try session.close()
    }
}
