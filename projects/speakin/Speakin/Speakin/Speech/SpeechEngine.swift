//
//  SpeechEngine.swift
//  Speakin
//
//  Thin wrapper over Apple's on-device SpeechAnalyzer (macOS 26). Two module kinds:
//  SpeechTranscriber (long-form, highest quality) and DictationTranscriber (the keyboard
//  dictation engine, more locales). Both run fully offline.
//

import AVFoundation
import Foundation
import Speech
import os

nonisolated enum SpeechEngineKind: String, Codable, Sendable, CaseIterable {
    case speechTranscriber
    case dictationTranscriber

    var displayName: String {
        switch self {
        case .speechTranscriber: "Apple Speech"
        case .dictationTranscriber: "Apple Dictation"
        }
    }
}

nonisolated struct SpeechLocaleOption: Hashable, Sendable, Identifiable {
    let locale: Locale
    let kind: SpeechEngineKind

    var id: String { "\(kind.rawValue)|\(locale.identifier)" }

    var displayName: String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }
}

nonisolated enum SpeechEngineError: LocalizedError {
    case unsupportedLocale(String)
    case noCompatibleFormat
    case converterUnavailable
    case emptyAudio

    var errorDescription: String? {
        switch self {
        case .unsupportedLocale(let id): "No on-device speech model supports \(id)."
        case .noCompatibleFormat: "The speech model reported no compatible audio format."
        case .converterUnavailable: "Could not convert microphone audio to the speech model's format."
        case .emptyAudio: "The recording contains no audio."
        }
    }
}

/// Collects module results from any thread. Final results are appended in order; the last
/// volatile (still-changing) result is kept separately so live previews can show it.
nonisolated final class TranscriptSink: @unchecked Sendable {
    private let lock = NSLock()
    private var finals: [String] = []
    private var volatile = ""

    func handle(_ text: AttributedString, isFinal: Bool) {
        let string = String(text.characters)
        lock.lock()
        defer { lock.unlock() }
        if isFinal {
            finals.append(string)
            volatile = ""
        } else {
            volatile = string
        }
    }

    /// Only finalized text — what gets stored and pasted.
    var finalizedText: String {
        lock.lock()
        defer { lock.unlock() }
        return Self.clean(finals.joined())
    }

    /// Finalized text plus the in-flight tail, for previews.
    var previewText: String {
        lock.lock()
        defer { lock.unlock() }
        return Self.clean(finals.joined() + volatile)
    }

    private static func clean(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// SpeechAnalyzer traps when two analyses run at once in one process, so every analysis takes its turn
/// here. Urgent work — live dictation, or a dictation read back from its file — never waits behind a
/// long recording: the recording's analysis is stopped, and starts over once the urgent work is done.
actor AnalyzerLane {
    static let shared = AnalyzerLane()

    private struct Turn {
        let urgent: Bool
        var yield: (@Sendable () async -> Void)?
    }

    private var current: Turn?
    private var waiting: [(urgent: Bool, continuation: CheckedContinuation<Void, Never>)] = []

    /// Waits for the lane. `yield` makes the turn interruptible by urgent work: it must stop the
    /// analysis promptly, and the caller then queues up again.
    func enter(urgent: Bool, yield: (@Sendable () async -> Void)? = nil) async {
        while let turn = current {
            if urgent, !turn.urgent, let stop = turn.yield {
                current?.yield = nil
                Task { await stop() }
            }
            await withCheckedContinuation { waiting.append((urgent, $0)) }
        }
        current = Turn(urgent: urgent, yield: yield)
    }

    func leave() {
        current = nil
        guard !waiting.isEmpty else { return }
        let next = waiting.firstIndex { $0.urgent } ?? 0
        waiting.remove(at: next).continuation.resume()
    }
}

/// Lets a file's analysis be stopped by urgent work exactly once, and tells afterwards whether it was.
nonisolated private final class Interruption: @unchecked Sendable {
    private let lock = NSLock()
    private var state = 0   // 0 running, 1 finished, 2 interrupted

    /// True if the analysis was still running and must now be stopped.
    func interrupt() -> Bool {
        lock.withLock {
            guard state == 0 else { return false }
            state = 2
            return true
        }
    }

    func finish() {
        lock.withLock { if state == 0 { state = 1 } }
    }

    var wasInterrupted: Bool { lock.withLock { state == 2 } }
}

/// One live (microphone) analysis session. `feed` is safe to call from the audio thread.
nonisolated final class LiveTranscriptionSession: @unchecked Sendable {
    private let analyzer: SpeechAnalyzer
    private let module: any SpeechModule
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let converter: AudioFormatConverter?
    private let sink: TranscriptSink
    private let resultsTask: Task<Void, Error>
    private let lock = NSLock()
    private var finished = false
    private var laneReleased = false

    fileprivate init(analyzer: SpeechAnalyzer,
                     module: any SpeechModule,
                     continuation: AsyncStream<AnalyzerInput>.Continuation,
                     converter: AudioFormatConverter?,
                     sink: TranscriptSink,
                     resultsTask: Task<Void, Error>) {
        self.analyzer = analyzer
        self.module = module
        self.continuation = continuation
        self.converter = converter
        self.sink = sink
        self.resultsTask = resultsTask
    }

    var previewText: String { sink.previewText }

    func feed(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        let outgoing: AVAudioPCMBuffer?
        if let converter {
            outgoing = converter.convert(buffer)
        } else {
            outgoing = buffer.speakin_copy()
        }
        guard let outgoing else { return }
        continuation.yield(AnalyzerInput(buffer: outgoing))
    }

    /// Ends input, waits for the model to finalize everything, and returns the full text.
    func finish() async throws -> String {
        markFinished()
        continuation.finish()
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            try await resultsTask.value
        } catch {
            await releaseLane()
            throw error
        }
        await releaseLane()
        return sink.finalizedText
    }

    func cancel() async {
        markFinished()
        continuation.finish()
        await analyzer.cancelAndFinishNow()
        resultsTask.cancel()
        await releaseLane()
    }

    deinit {
        // A session dropped without finishing must not hold every later transcription up.
        if claimLaneRelease() { Task { await AnalyzerLane.shared.leave() } }
    }

    private func markFinished() {
        lock.lock()
        finished = true
        lock.unlock()
    }

    private func releaseLane() async {
        if claimLaneRelease() { await AnalyzerLane.shared.leave() }
    }

    private func claimLaneRelease() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !laneReleased else { return false }
        laneReleased = true
        return true
    }
}

nonisolated final class SpeechEngine: @unchecked Sendable {
    let locale: Locale
    let kind: SpeechEngineKind
    private let options = SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)
    private let contextLock = NSLock()
    private var _contextualStrings: [String] = []

    /// Names and terms the model should prefer ("Nocaps", "Knomo"). Applied to every new session.
    var contextualStrings: [String] {
        get { contextLock.lock(); defer { contextLock.unlock() }; return _contextualStrings }
        set { contextLock.lock(); _contextualStrings = newValue; contextLock.unlock() }
    }

    init(locale: Locale, kind: SpeechEngineKind, contextualStrings: [String] = []) {
        self.locale = locale
        self.kind = kind
        _contextualStrings = contextualStrings
    }

    private func makeContext() -> AnalysisContext? {
        let strings = contextualStrings
        guard !strings.isEmpty else { return nil }
        let context = AnalysisContext()
        context.contextualStrings[.general] = strings
        return context
    }

    // MARK: - Locales

    /// Every locale some on-device module can handle. SpeechTranscriber entries come first;
    /// a locale only the dictation engine supports is listed under that kind.
    static func availableOptions() async -> [SpeechLocaleOption] {
        var options: [SpeechLocaleOption] = []
        var seen = Set<String>()
        for locale in await SpeechTranscriber.supportedLocales {
            let key = locale.identifier(.bcp47)
            guard seen.insert(key).inserted else { continue }
            options.append(SpeechLocaleOption(locale: locale, kind: .speechTranscriber))
        }
        for locale in await DictationTranscriber.supportedLocales {
            let key = locale.identifier(.bcp47)
            guard seen.insert(key).inserted else { continue }
            options.append(SpeechLocaleOption(locale: locale, kind: .dictationTranscriber))
        }
        return options.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// Best module for a wanted locale, preferring SpeechTranscriber.
    static func resolve(preferred: Locale) async -> SpeechLocaleOption? {
        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: preferred) {
            return SpeechLocaleOption(locale: match, kind: .speechTranscriber)
        }
        if let match = await DictationTranscriber.supportedLocale(equivalentTo: preferred) {
            return SpeechLocaleOption(locale: match, kind: .dictationTranscriber)
        }
        return nil
    }

    // MARK: - Assets

    func assetStatus() async -> AssetInventory.Status {
        await AssetInventory.status(forModules: [makeModule()])
    }

    /// Downloads and installs the model for this locale if needed. Progress is 0...1.
    func ensureAssets(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let module = makeModule()
        let status = await AssetInventory.status(forModules: [module])
        if status == .unsupported { throw SpeechEngineError.unsupportedLocale(locale.identifier) }
        if status == .installed { return }

        // Ask the system to keep this locale's assets around. Failing to reserve is not fatal.
        _ = try? await AssetInventory.reserve(locale: locale)

        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else { return }
        let observation = request.progress.observe(\.fractionCompleted, options: [.initial, .new]) { p, _ in
            progress?(p.fractionCompleted)
        }
        defer { observation.invalidate() }
        try await request.downloadAndInstall()
        progress?(1)
    }

    /// Loads the model into memory ahead of the first speech.
    func warmUp(inputFormat: AVAudioFormat?) async throws {
        let module = makeModule()
        let analyzer = SpeechAnalyzer(modules: [module], options: options)
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module], considering: inputFormat)
        try await analyzer.prepareToAnalyze(in: format)
    }

    // MARK: - Sessions

    func makeModule() -> any SpeechModule {
        switch kind {
        case .speechTranscriber:
            return SpeechTranscriber(locale: locale,
                                     transcriptionOptions: [],
                                     reportingOptions: [.volatileResults],
                                     attributeOptions: [])
        case .dictationTranscriber:
            return DictationTranscriber(locale: locale,
                                        contentHints: [],
                                        transcriptionOptions: [.punctuation],
                                        reportingOptions: [.volatileResults],
                                        attributeOptions: [])
        }
    }

    /// Starts a streaming session for microphone audio arriving in `inputFormat`. A file being
    /// transcribed meanwhile is interrupted (two analyzers at once crash Speech) and resumes afterwards.
    func startLiveSession(inputFormat: AVAudioFormat) async throws -> LiveTranscriptionSession {
        await AnalyzerLane.shared.enter(urgent: true)
        do {
            return try await makeLiveSession(inputFormat: inputFormat)
        } catch {
            await AnalyzerLane.shared.leave()
            throw error
        }
    }

    private func makeLiveSession(inputFormat: AVAudioFormat) async throws -> LiveTranscriptionSession {
        let module = makeModule()
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module],
                                                                                  considering: inputFormat) else {
            throw SpeechEngineError.noCompatibleFormat
        }
        let converter: AudioFormatConverter?
        if analyzerFormat == inputFormat {
            converter = nil
        } else {
            guard let c = AudioFormatConverter(from: inputFormat, to: analyzerFormat) else {
                throw SpeechEngineError.converterUnavailable
            }
            converter = c
        }

        let sink = TranscriptSink()
        let resultsTask = Self.collectResults(of: module, into: sink)
        let analyzer = SpeechAnalyzer(modules: [module], options: options)
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        do {
            if let context = makeContext() { try await analyzer.setContext(context) }
            try await analyzer.start(inputSequence: stream)
        } catch {
            continuation.finish()
            resultsTask.cancel()
            throw error
        }
        return LiveTranscriptionSession(analyzer: analyzer,
                                        module: module,
                                        continuation: continuation,
                                        converter: converter,
                                        sink: sink,
                                        resultsTask: resultsTask)
    }

    /// Transcribes an audio file from disk (recovery, re-transcription, recorded sessions). `urgent` is
    /// for a dictation someone is waiting on; anything else gives way to dictation and starts over after.
    func transcribe(fileAt url: URL, urgent: Bool = false) async throws -> String {
        while true {
            let file = try AVAudioFile(forReading: url)
            guard file.length > 0 else { throw SpeechEngineError.emptyAudio }
            let module = makeModule()
            let analyzer = SpeechAnalyzer(modules: [module], options: options)
            let interruption = Interruption()
            let stop: @Sendable () async -> Void = {
                guard interruption.interrupt() else { return }
                await analyzer.cancelAndFinishNow()
            }
            await AnalyzerLane.shared.enter(urgent: urgent, yield: urgent ? nil : stop)
            let result: Result<String, Error>
            do {
                result = .success(try await analyze(file, module: module, analyzer: analyzer))
            } catch {
                result = .failure(error)
            }
            interruption.finish()
            await AnalyzerLane.shared.leave()
            guard interruption.wasInterrupted else { return try result.get() }
            Log.speech.info("transcription of \(url.lastPathComponent, privacy: .public) gave way to dictation; starting it again")
            try Task.checkCancellation()
        }
    }

    private func analyze(_ file: AVAudioFile, module: any SpeechModule, analyzer: SpeechAnalyzer) async throws -> String {
        let sink = TranscriptSink()
        let resultsTask = Self.collectResults(of: module, into: sink)
        do {
            if let context = makeContext() { try await analyzer.setContext(context) }
            if let lastSample = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: lastSample)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            await analyzer.cancelAndFinishNow()
            resultsTask.cancel()
            throw error
        }
        try await resultsTask.value
        return sink.finalizedText
    }

    // MARK: - Results plumbing

    private static func collectResults(of module: any SpeechModule, into sink: TranscriptSink) -> Task<Void, Error> {
        if let transcriber = module as? SpeechTranscriber {
            return Task.detached(priority: .userInitiated) {
                for try await result in transcriber.results {
                    sink.handle(result.text, isFinal: result.isFinal)
                }
            }
        }
        if let dictation = module as? DictationTranscriber {
            return Task.detached(priority: .userInitiated) {
                for try await result in dictation.results {
                    sink.handle(result.text, isFinal: result.isFinal)
                }
            }
        }
        return Task.detached {}
    }
}
