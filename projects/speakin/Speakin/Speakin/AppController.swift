//
//  AppController.swift
//  Speakin
//
//  The state machine behind the overlay and the menu:
//  idle → recording → transcribing → pasted/copied/failed → idle.
//

import AppKit
import AVFoundation
import Combine
import Foundation
import os

/// Bridges the recorder's serial queue to the live transcription session. Buffers audio while the
/// session is still starting so the first words are never missed.
nonisolated private final class LiveFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var session: LiveTranscriptionSession?
    private var pending: [AVAudioPCMBuffer] = []
    private var pendingFrames: AVAudioFrameCount = 0
    private var buffering: Bool
    private var closed = false
    private let maxPendingFrames: AVAudioFrameCount = 16_000 * 60 * 5

    init(buffering: Bool) {
        self.buffering = buffering
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        if let session {
            session.feed(buffer)
        } else if buffering, pendingFrames < maxPendingFrames {
            pending.append(buffer)
            pendingFrames += buffer.frameLength
        }
    }

    /// Returns false if the recording already ended; the caller must then cancel the session.
    func attach(_ session: LiveTranscriptionSession) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return false }
        self.session = session
        for buffer in pending { session.feed(buffer) }
        pending.removeAll()
        pendingFrames = 0
        return true
    }

    func attachFailed() {
        lock.lock()
        defer { lock.unlock() }
        buffering = false
        pending.removeAll()
        pendingFrames = 0
    }

    var previewText: String {
        lock.lock()
        defer { lock.unlock() }
        return session?.previewText ?? ""
    }

    func close() -> LiveTranscriptionSession? {
        lock.lock()
        defer { lock.unlock() }
        closed = true
        pending.removeAll()
        let s = session
        session = nil
        return s
    }
}

@MainActor
final class AppController: ObservableObject {
    static let shared = AppController()

    enum Phase: Equatable {
        case starting(String)
        case idle
        case recording(since: Date)
        case transcribing
        case pasted
        case copied
        case heardNothing
        case failed(String)

        var isRecording: Bool {
            if case .recording = self { return true }
            return false
        }
    }

    @Published private(set) var phase: Phase = .starting("Starting…")
    @Published private(set) var level: Float = 0
    @Published private(set) var livePreview: String = ""
    @Published private(set) var engineOption: SpeechLocaleOption?
    @Published private(set) var availableLocales: [SpeechLocaleOption] = []
    @Published private(set) var modelProgress: Double?
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var microphoneGranted = false
    @Published private(set) var lastError: String?
    @Published private(set) var recoveredCount = 0

    let store: TranscriptionStore
    let vocabulary: VocabularyStore
    let settings = Settings.shared
    let hotkey = Hotkey.default

    private let hotkeyManager = HotkeyManager()
    private let recorder = AudioRecorder()
    private var engine: SpeechEngine?
    private var enginePreparation: Task<SpeechEngine, Error>?
    private var active: ActiveRecording?
    private var resetTask: Task<Void, Never>?
    private var previewTimer: Timer?
    private var retranscribing = Set<String>()
    private var cancellables = Set<AnyCancellable>()

    private struct ActiveRecording {
        var record: TranscriptionRecord
        let audioURL: URL
        let feed: LiveFeed
        let startedAt: Date
    }

    private init() {
        do {
            store = try TranscriptionStore()
        } catch {
            fatalError("Speakin cannot create its data folder: \(error)")
        }
        vocabulary = VocabularyStore(directory: store.rootURL)
    }

    // MARK: - Lifecycle

    func start() {
        store.load()
        store.enforceRetention()
        vocabulary.load()
        vocabulary.$entries.combineLatest(vocabulary.$ignored)
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
                guard let self else { return }
                self.engine?.contextualStrings = self.vocabulary.contextualStrings
            }
            .store(in: &cancellables)
        Task { [weak self] in await self?.vocabulary.rescanIfStale() }

        do {
            try hotkeyManager.register(hotkey)
            hotkeyManager.onPress = { [weak self] in self?.toggle() }
            Log.app.info("hotkey \(self.hotkey.displayString, privacy: .public) registered")
        } catch {
            lastError = error.localizedDescription
            Log.app.error("hotkey registration failed: \(error.localizedDescription, privacy: .public)")
        }
        Log.app.info("settings: autoPaste=\(self.settings.autoPaste) sounds=\(self.settings.soundsEnabled) locale=\(self.settings.localeIdentifier ?? "system", privacy: .public)")
        Log.store.info("data folder: \(self.store.rootURL.path, privacy: .public); \(self.store.records.count) records, \(self.store.records.filter(\.needsTranscription).count) pending")

        accessibilityGranted = Paster.isAccessibilityTrusted(prompt: false)
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissions() }
        }

        Task { [weak self] in
            let granted = await AudioRecorder.requestMicrophoneAccess()
            guard let self else { return }
            self.microphoneGranted = granted
            Log.audio.info("microphone access granted: \(granted)")
            if !granted { self.lastError = AudioRecorderError.microphoneDenied.localizedDescription }
            if granted, !self.accessibilityGranted {
                self.accessibilityGranted = Paster.isAccessibilityTrusted(prompt: true)
            }
        }

        prepareEngine()
    }

    func refreshPermissions() {
        accessibilityGranted = Paster.isAccessibilityTrusted(prompt: false)
        microphoneGranted = AudioRecorder.microphoneAuthorized
    }

    func requestAccessibility() {
        accessibilityGranted = Paster.isAccessibilityTrusted(prompt: true)
        if !accessibilityGranted { Paster.openAccessibilitySettings() }
    }

    func willTerminate() {
        guard let active else { return }
        // Leave the audio on disk marked pending; it is transcribed on the next launch.
        self.active = nil
        _ = active.feed.close()
        var record = active.record
        record.duration = (try? recorder.stop()) ?? record.duration
        record.status = .pending
        store.save(record)
    }

    // MARK: - Engine preparation

    private func preferredLocale() -> Locale {
        if let id = settings.localeIdentifier { return Locale(identifier: id) }
        return Locale.current
    }

    private func prepareEngine() {
        enginePreparation?.cancel()
        engine = nil
        modelProgress = nil
        if !phase.isRecording { phase = .starting("Preparing speech model…") }

        let preferred = preferredLocale()
        let task = Task<SpeechEngine, Error> { [weak self] in
            let options = await SpeechEngine.availableOptions()
            await MainActor.run { self?.availableLocales = options }

            var resolved = await SpeechEngine.resolve(preferred: preferred)
            if resolved == nil { resolved = await SpeechEngine.resolve(preferred: Locale(identifier: "en_US")) }
            guard let option = resolved else {
                throw SpeechEngineError.unsupportedLocale(preferred.identifier)
            }
            await MainActor.run { self?.engineOption = option }

            let engine = SpeechEngine(locale: option.locale, kind: option.kind,
                                      contextualStrings: await MainActor.run { self?.vocabulary.contextualStrings ?? [] })
            try await engine.ensureAssets { progress in
                Task { @MainActor in
                    self?.modelProgress = progress
                    if let self, !self.phase.isRecording {
                        self.phase = .starting("Downloading \(option.displayName) model… \(Int(progress * 100))%")
                    }
                }
            }
            try Task.checkCancellation()
            try await engine.warmUp(inputFormat: AudioRecorder.canonicalFormat)
            return engine
        }
        enginePreparation = task

        Task { [weak self] in
            do {
                let engine = try await task.value
                guard let self, self.enginePreparation == task else { return }
                self.engine = engine
                self.modelProgress = nil
                Log.speech.info("engine ready: \(engine.locale.identifier, privacy: .public) via \(engine.kind.rawValue, privacy: .public)")
                if case .starting = self.phase { self.phase = .idle }
                self.recoverPendingRecordings()
            } catch is CancellationError {
                // superseded by another preparation
            } catch {
                guard let self, self.enginePreparation == task else { return }
                self.lastError = error.localizedDescription
                Log.speech.error("engine preparation failed: \(error.localizedDescription, privacy: .public)")
                if case .starting = self.phase { self.phase = .failed(error.localizedDescription) }
            }
        }
    }

    private func readyEngine() async throws -> SpeechEngine {
        if let engine { return engine }
        guard let enginePreparation else { throw SpeechEngineError.unsupportedLocale(preferredLocale().identifier) }
        return try await enginePreparation.value
    }

    func selectLocale(_ option: SpeechLocaleOption?) {
        settings.localeIdentifier = option?.locale.identifier
        prepareEngine()
    }

    // MARK: - Recording

    func toggle() {
        switch phase {
        case .recording:
            stopAndTranscribe()
        case .transcribing:
            break
        default:
            startRecording()
        }
    }

    func startIfIdle() {
        guard !phase.isRecording, phase != .transcribing else { return }
        startRecording()
    }

    func stopIfRecording() {
        guard phase.isRecording else { return }
        stopAndTranscribe()
    }

    private func startRecording() {
        guard active == nil else { return }
        resetTask?.cancel()

        let now = Date()
        let id = TranscriptionRecord.makeID(date: now)
        let audioURL = store.newAudioURL(id: id)
        var record = TranscriptionRecord(id: id, createdAt: now, updatedAt: now, duration: 0,
                                         status: .recording, text: "", rawText: nil, error: nil,
                                         localeIdentifier: engineOption?.locale.identifier,
                                         engine: engineOption?.kind.rawValue,
                                         audioFileName: audioURL.lastPathComponent, pasted: false)

        let liveEngine = engine
        let feed = LiveFeed(buffering: liveEngine != nil)
        let callbacks = AudioRecorder.Callbacks(
            onBuffer: { buffer in feed.feed(buffer) },
            onLevel: { [weak self] level in
                Task { @MainActor [weak self] in self?.level = level }
            },
            onInterruption: { [weak self] in
                Task { @MainActor [weak self] in self?.handleInterruption() }
            }
        )

        do {
            try recorder.start(writingTo: audioURL, callbacks: callbacks)
        } catch {
            Log.audio.error("recording failed to start: \(error.localizedDescription, privacy: .public)")
            fail(error.localizedDescription)
            return
        }
        Log.audio.info("recording \(id, privacy: .public) started (live session: \(liveEngine != nil))")

        record.status = .recording
        store.save(record)
        active = ActiveRecording(record: record, audioURL: audioURL, feed: feed, startedAt: now)
        livePreview = ""
        phase = .recording(since: now)
        playSound("Tink")

        if let liveEngine {
            Task.detached(priority: .userInitiated) {
                do {
                    let session = try await liveEngine.startLiveSession(inputFormat: AudioRecorder.canonicalFormat)
                    if !feed.attach(session) { await session.cancel() }
                } catch {
                    feed.attachFailed()
                    Log.speech.error("live session failed, will transcribe from file: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        previewTimer?.invalidate()
        previewTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let active = self.active else { return }
                let text = active.feed.previewText
                if text != self.livePreview { self.livePreview = text }
            }
        }
    }

    private func handleInterruption() {
        guard phase.isRecording else { return }
        stopAndTranscribe()
    }

    private func stopAndTranscribe() {
        guard let active else { return }
        self.active = nil
        previewTimer?.invalidate()
        previewTimer = nil
        level = 0
        phase = .transcribing
        playSound("Pop")

        var record = active.record
        do {
            record.duration = try recorder.stop()
        } catch {
            Log.audio.error("recorder stop error: \(error.localizedDescription, privacy: .public)")
            _ = try? WAVWriter.repairHeader(at: active.audioURL)
            record.duration = active.startedAt.distance(to: Date())
        }
        record.status = .transcribing
        store.save(record)
        Log.audio.info("recording \(record.id, privacy: .public) stopped after \(record.duration, format: .fixed(precision: 1))s")

        let session = active.feed.close()
        let audioURL = active.audioURL

        Task { [weak self] in
            guard let self else { return }
            var record = record
            let started = Date()
            do {
                let raw = try await self.transcribe(session: session, audioURL: audioURL)
                Log.speech.info("transcribed \(record.id, privacy: .public): \(raw.count) chars in \(Date().timeIntervalSince(started), format: .fixed(precision: 2))s (live: \(session != nil))")
                let text = self.postProcess(raw, localeIdentifier: record.localeIdentifier)
                record.status = .completed
                record.text = text
                record.rawText = text == raw ? nil : raw
                record.error = nil

                if text.isEmpty {
                    self.store.save(record)
                    self.phase = .heardNothing
                } else if self.settings.autoPaste {
                    let pasted = await Paster.paste(text)
                    record.pasted = pasted
                    self.store.save(record)
                    Log.app.info("\(pasted ? "pasted" : "copied only (no Accessibility)", privacy: .public)")
                    self.phase = pasted ? .pasted : .copied
                    if !pasted { self.accessibilityGranted = Paster.isAccessibilityTrusted(prompt: false) }
                } else {
                    Paster.copy(text)
                    self.store.save(record)
                    Log.app.info("copied (auto-paste off)")
                    self.phase = .copied
                }
            } catch {
                record.status = .failed
                record.error = error.localizedDescription
                self.store.save(record)
                Log.speech.error("transcription of \(record.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                self.fail(error.localizedDescription)
            }
            self.livePreview = ""
            self.store.enforceRetention()
            self.scheduleReturnToIdle()
        }
    }

    private func transcribe(session: LiveTranscriptionSession?, audioURL: URL) async throws -> String {
        if let session {
            do {
                return try await session.finish()
            } catch {
                Log.speech.error("live finish failed, falling back to file: \(error.localizedDescription, privacy: .public)")
            }
        }
        let engine = try await readyEngine()
        _ = try? WAVWriter.repairHeader(at: audioURL)
        return try await engine.transcribe(fileAt: audioURL)
    }

    /// Filler removal, then vocabulary fixes. Both keep the model's output in `rawText`.
    private func postProcess(_ raw: String, localeIdentifier: String?) -> String {
        let localeIdentifier = localeIdentifier ?? engineOption?.locale.identifier ?? "en_US"
        var text = raw
        if settings.removeFillerWords {
            text = TranscriptCleaner.removeFillerWords(from: text, locale: Locale(identifier: localeIdentifier))
        }
        if settings.vocabularyEnabled {
            let language = WordOracle.shared.spellLanguage(for: localeIdentifier)
            let fixer = VocabularyFixer(
                terms: vocabulary.terms,
                corrections: vocabulary.corrections,
                isRealWord: { word in MainActor.assumeIsolated { WordOracle.shared.isRealWord(word, language: language) } },
                isCommonPhrase: { WordOracle.isCommonPhrase($0) }
            )
            let result = fixer.fix(text)
            if !result.replacements.isEmpty {
                Log.speech.info("vocabulary fixes: \(result.replacements.map { "\($0.heard) → \($0.term)" }.joined(separator: ", "), privacy: .public)")
            }
            if !result.candidates.isEmpty {
                Log.speech.info("vocabulary candidates left alone: \(result.candidates.map { "\($0.heard) ~ \($0.term)" }.joined(separator: ", "), privacy: .public)")
            }
            text = result.text
        }
        return text
    }

    private func fail(_ message: String) {
        lastError = message
        phase = .failed(message)
        playSound("Basso")
        scheduleReturnToIdle(after: 4)
    }

    private func scheduleReturnToIdle(after seconds: TimeInterval = 1.4) {
        resetTask?.cancel()
        resetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            switch self.phase {
            case .pasted, .copied, .heardNothing, .failed:
                self.phase = self.engine == nil && self.enginePreparation != nil ? .starting("Preparing speech model…") : .idle
            default:
                break
            }
        }
    }

    private func playSound(_ name: String) {
        guard settings.soundsEnabled else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }

    // MARK: - Recovery & re-transcription

    /// Transcribes every recording that never got its text (app crash, model missing, …).
    func recoverPendingRecordings() {
        let pending = store.records.filter(\.needsTranscription)
        guard !pending.isEmpty else { return }
        Log.speech.info("recovering \(pending.count) untranscribed recording(s)")
        for record in pending { retranscribe(record, markRecovered: true) }
    }

    func retranscribe(_ record: TranscriptionRecord, markRecovered: Bool = false) {
        guard !retranscribing.contains(record.id), let audioURL = store.audioURL(for: record) else { return }
        retranscribing.insert(record.id)
        Task { [weak self] in
            guard let self else { return }
            defer { self.retranscribing.remove(record.id) }
            var record = record
            do {
                let engine = try await self.readyEngine()
                _ = try? WAVWriter.repairHeader(at: audioURL)
                record.status = .transcribing
                record.engine = engine.kind.rawValue
                record.localeIdentifier = engine.locale.identifier
                if record.duration == 0, let file = try? AVAudioFile(forReading: audioURL) {
                    record.duration = Double(file.length) / file.processingFormat.sampleRate
                }
                self.store.save(record)
                let raw = try await engine.transcribe(fileAt: audioURL)
                let text = self.postProcess(raw, localeIdentifier: record.localeIdentifier)
                record.status = .completed
                record.text = text
                record.rawText = text == raw ? nil : raw
                record.error = nil
                self.store.save(record)
                if markRecovered { self.recoveredCount += 1 }
                Log.speech.info("re-transcribed \(record.id, privacy: .public): \(text.count) chars")
            } catch {
                record.status = .failed
                record.error = error.localizedDescription
                self.store.save(record)
                Log.speech.error("re-transcription of \(record.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Convenience for UI

    var statusLine: String {
        switch phase {
        case .starting(let s): s
        case .idle: "Ready — press \(hotkey.displayString) to speak"
        case .recording(let since): "Recording… \(Self.format(Date().timeIntervalSince(since)))"
        case .transcribing: "Transcribing…"
        case .pasted: "Pasted"
        case .copied: settings.autoPaste ? "Copied to clipboard (Accessibility needed to paste)" : "Copied to clipboard"
        case .heardNothing: "Heard nothing"
        case .failed(let message): "Failed: \(message)"
        }
    }

    nonisolated static func format(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        return s >= 60 ? String(format: "%d:%02d", s / 60, s % 60) : "\(s)s"
    }
}
