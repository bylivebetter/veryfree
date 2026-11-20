//
//  SessionController.swift
//  Speakin
//
//  Recording what the Mac plays — a call, a video, anything — together with your voice, to a file
//  you can open, keep or edit, with an optional transcript beside it.
//
//  The hotkey always does something: start, stop, or — pressed while a recording is starting or
//  saving — the opposite as soon as that step is done. Transcription runs on the side and never
//  stands in the way of the next recording.
//

import AppKit
import Combine
import Foundation
import os

@MainActor
final class SessionController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case starting
        case recording(since: Date)
        case finishing
        case failed(String)

        var isRecording: Bool {
            if case .recording = self { return true }
            return false
        }

        /// Starting or saving: a press now is remembered and acted on when the step is done.
        var isTransitioning: Bool { self == .starting || self == .finishing }
    }

    @Published private(set) var phase: Phase = .idle
    /// Live details while recording: which microphone, and whether anything is coming through.
    @Published private(set) var status = SessionRecorder.Status()
    /// Set when nothing has come through the tap — usually the Audio Recording permission.
    @Published private(set) var silentSystemAudio = false
    @Published private(set) var lastError: String?
    /// Recordings being transcribed right now.
    @Published private(set) var transcribing = Set<String>()

    let store: SessionStore
    let settings = Settings.shared

    private let recorder = SessionRecorder()
    private let transcribe: (URL) async throws -> String
    private var current: SessionRecord?
    private var pendingToggle = false

    init(supportDirectory: URL, transcribe: @escaping (URL) async throws -> String) {
        store = SessionStore(supportDirectory: supportDirectory, folderURL: Settings.shared.sessionsFolder)
        self.transcribe = transcribe
    }

    func start() {
        store.load()
        // Finish what a crash or a quit left behind: the fragments on disk are a playable recording.
        for session in store.sessions where session.transcriptStatus == .pending || session.transcriptStatus == .running {
            transcribeSession(session)
        }
    }

    var source: SystemAudioSource {
        get { settings.sessionSource }
        set {
            settings.sessionSource = newValue
            objectWillChange.send()
        }
    }

    /// Whose voice is mixed in. Changing it mid-recording switches at once.
    var microphone: MicrophoneChoice {
        get { settings.sessionMicrophone }
        set {
            settings.sessionMicrophone = newValue
            recorder.setMicrophone(newValue)
            objectWillChange.send()
        }
    }

    // MARK: - Recording

    func toggle() {
        switch phase {
        case .idle, .failed: startRecording()
        case .recording: stop()
        case .starting, .finishing: pendingToggle.toggle()
        }
    }

    func startRecording() {
        switch phase {
        case .idle, .failed: break
        case .finishing:
            pendingToggle = true
            return
        case .starting, .recording:
            return
        }
        guard store.ensureFolder() else {
            fail("Cannot write to \(store.folderURL.path).")
            return
        }

        let source = settings.sessionSource
        let microphone = settings.sessionMicrophone
        let fileName = store.newFileName(source: source)
        let url = store.folderURL.appendingPathComponent(fileName)
        let record = SessionRecord(id: UUID().uuidString, fileName: fileName, createdAt: Date(), duration: 0,
                                   status: .recording, sourceName: source.displayName, bundleID: source.bundleID,
                                   includedMicrophone: microphone != .off, capturedSystemAudio: false,
                                   transcriptStatus: settings.transcribeSessions ? .pending : .none,
                                   transcriptFileName: nil, error: nil)
        let callbacks = SessionRecorder.Callbacks(
            onStatus: { [weak self] status in
                Task { @MainActor [weak self] in self?.apply(status) }
            },
            onWriteFailure: { [weak self] error in
                Task { @MainActor [weak self] in self?.handleWriteFailure(error) }
            }
        )

        phase = .starting
        status = SessionRecorder.Status()
        silentSystemAudio = false
        lastError = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.recorder.start(writingTo: url, source: source, microphone: microphone, callbacks: callbacks)
                self.current = record
                self.store.save(record)
                self.phase = .recording(since: Date())
                self.playSound("Submarine")
                Log.audio.info("session recording started → \(fileName, privacy: .public)")
            } catch {
                Log.audio.error("session recording failed to start: \(error.localizedDescription, privacy: .public)")
                self.pendingToggle = false
                self.fail(error.localizedDescription)
                return
            }
            self.honourPendingToggle()
        }
    }

    func stop() {
        switch phase {
        case .recording: break
        case .starting:
            pendingToggle = true
            return
        default:
            return
        }
        guard var record = current else { return }
        current = nil
        phase = .finishing
        playSound("Submarine")

        Task { [weak self] in
            guard let self else { return }
            let summary = await self.recorder.stop()
            record.duration = summary.duration
            record.capturedSystemAudio = summary.capturedSystemAudio
            record.includedMicrophone = !summary.microphones.isEmpty
            record.microphoneName = summary.microphones.isEmpty ? nil : summary.microphones.joined(separator: " → ")
            record.status = summary.duration > 0 ? .completed : .failed
            record.error = summary.problem
            // The setting as it is now, not as it was when the recording started.
            let transcribe = record.status == .completed && self.settings.transcribeSessions
            record.transcriptStatus = transcribe ? .pending : .none
            self.store.save(record)
            self.store.refresh()
            self.status = SessionRecorder.Status()
            self.silentSystemAudio = !summary.capturedSystemAudio && summary.duration > 2
            self.phase = .idle
            Log.audio.info("session recording saved: \(record.fileName, privacy: .public)")
            if transcribe { self.transcribeSession(record) }
            self.honourPendingToggle()
        }
    }

    private func honourPendingToggle() {
        guard pendingToggle else { return }
        pendingToggle = false
        toggle()
    }

    private func apply(_ status: SessionRecorder.Status) {
        guard case .recording(let since) = phase else { return }
        self.status = status
        silentSystemAudio = !status.capturedSystemAudio && Date().timeIntervalSince(since) > 6
    }

    private func handleWriteFailure(_ error: Error) {
        guard phase.isRecording else { return }
        lastError = error.localizedDescription
        stop()
    }

    /// Quitting mid-recording: close the file properly if there is time, otherwise the fragments
    /// already on disk stand on their own and the next launch finishes the bookkeeping.
    func willTerminate() {
        guard phase.isRecording, var record = current else { return }
        current = nil
        guard let summary = recorder.stopBlocking(timeout: 4) else { return }
        record.status = .completed
        record.duration = summary.duration
        record.capturedSystemAudio = summary.capturedSystemAudio
        record.microphoneName = summary.microphones.isEmpty ? nil : summary.microphones.joined(separator: " → ")
        store.save(record)
    }

    // MARK: - Transcription

    func transcribeSession(_ session: SessionRecord) {
        guard !transcribing.contains(session.id) else { return }
        let url = store.fileURL(for: session)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        transcribing.insert(session.id)

        var record = session
        record.transcriptStatus = .running
        store.save(record)

        Task { [weak self] in
            guard let self else { return }
            let started = Date()
            do {
                let text = try await self.transcribe(url)
                record = self.store.saveTranscript(text, for: record)
                Log.speech.info("session transcript: \(record.fileName, privacy: .public), \(text.count) chars in \(Date().timeIntervalSince(started), format: .fixed(precision: 1))s")
            } catch {
                record.transcriptStatus = .failed
                record.error = error.localizedDescription
                self.store.save(record)
                Log.speech.error("session transcript failed: \(error.localizedDescription, privacy: .public)")
            }
            self.transcribing.remove(session.id)
        }
    }

    // MARK: - Helpers

    private func fail(_ message: String) {
        lastError = message
        phase = .failed(message)
        playSound("Basso")
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, case .failed = self.phase else { return }
            self.phase = .idle
        }
    }

    private func playSound(_ name: String) {
        guard settings.soundsEnabled else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }

    func openAudioRecordingSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
    }

    var statusLine: String {
        switch phase {
        case .idle:
            let source = settings.sessionSource.displayName
            return "Record \(source) — \(Hotkey.session.displayString)"
        case .starting:
            return "Starting recording…"
        case .recording(let since):
            let elapsed = AppController.format(Date().timeIntervalSince(since))
            return silentSystemAudio ? "Recording \(elapsed) — no system audio yet" : "Recording \(elapsed)"
        case .finishing: return "Saving recording…"
        case .failed(let message): return "Recording failed: \(message)"
        }
    }
}
