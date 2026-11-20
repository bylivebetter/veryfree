//
//  SessionRecorder.swift
//  Speakin
//
//  Records a call — or anything the Mac plays — together with the user's microphone into one file,
//  and keeps recording through whatever the hardware does meanwhile: headphones plugged in, a
//  Bluetooth headset switching into call mode or reconnecting, a device unplugged, the Mac sleeping.
//  A capture that breaks is rebuilt within a second; the other one never notices.
//
//  Nothing ever waits on itself:
//  - each capture's IOProc runs on its own queue and only converts and mixes;
//  - captures are built, rebuilt and torn down on `control`, never on an IOProc queue;
//  - the file is written on `writing`, from the mixer, four times a second;
//  - callers only ever wait with a timeout, so a wedged audio daemon cannot freeze the app.
//

@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import Synchronization
import os

/// Whose voice goes into a recording: nobody's, the mic the call is using, or one picked by hand.
nonisolated enum MicrophoneChoice: Equatable, Sendable {
    case off
    case automatic
    case device(uid: String, name: String)
}

nonisolated final class SessionRecorder: @unchecked Sendable {
    /// What the menu shows while recording.
    struct Status: Equatable, Sendable {
        var capturedSystemAudio = false
        var systemAudioProblem: String?
        var microphoneName: String?
        var microphoneSilent = false
    }

    struct Summary: Sendable {
        var duration: TimeInterval = 0
        var capturedSystemAudio = false
        var microphones: [String] = []
        var problem: String?
    }

    struct Callbacks: Sendable {
        /// When the status changes, on a background queue.
        var onStatus: @Sendable (Status) -> Void
        /// The file can no longer be written (disk full, folder gone): the recording should stop.
        var onWriteFailure: @Sendable (Error) -> Void
    }

    private static let tick = 0.5
    private static let flushInterval = 0.25
    /// How far behind real time the file is written, so buffers that arrive late still find their place.
    private static let writeDelay = Int64(SessionMixer.sampleRate * 0.5)
    /// A capture that delivers nothing for this long has lost its device without saying so.
    private static let stallSeconds = 1.5

    private let control = DispatchQueue(label: "com.bylivebetter.speakin.session.control", qos: .userInitiated)
    private let writing = DispatchQueue(label: "com.bylivebetter.speakin.session.writing", qos: .userInitiated)
    private let systemQueue = DispatchQueue(label: "com.bylivebetter.speakin.session.system", qos: .userInteractive)
    private let microphoneQueue = DispatchQueue(label: "com.bylivebetter.speakin.session.microphone", qos: .userInteractive)
    private let active = OSAllocatedUnfairLock<Session?>(initialState: nil)
    /// For testing recovery: `-SpeakinTestChurnSeconds 5` rebuilds both captures every 5 s, as if the
    /// hardware kept changing under the recording.
    private let churnSeconds = UserDefaults.standard.double(forKey: "SpeakinTestChurnSeconds")

    /// Everything about one recording. Each field is owned by the queue it is marked with.
    private final class Session: @unchecked Sendable {
        let writer: SessionWriter
        let mixer: SessionMixer
        let source: SystemAudioSource
        let callbacks: Callbacks
        let capturedSystemAudio = Atomic<Bool>(false)
        let problem = OSAllocatedUnfairLock<String?>(initialState: nil)

        // control
        var microphoneChoice: MicrophoneChoice
        var system: (capture: SystemAudioCapture, input: MixerInput)?
        var microphone: (capture: MicrophoneCapture, input: MixerInput)?
        var systemProblem: Error?
        var lastSystemAttempt: UInt64 = 0
        var lastMicrophoneAttempt: UInt64 = 0
        var automaticMicrophone: AudioObjectID?
        var lastDefaultInput: AudioObjectID?
        var pendingMicrophone: (id: AudioObjectID, looks: Int)?
        var microphonesUsed: [String] = []
        var supervisor: DispatchSourceTimer?
        var ticks = 0
        var lastChurn: UInt64 = 0
        var lastStatus: Status?
        var peaks: (system: Float, microphone: Float) = (0, 0)

        // writing
        var flusher: DispatchSourceTimer?
        var writeFailed = false

        init(writer: SessionWriter, mixer: SessionMixer, source: SystemAudioSource, microphone: MicrophoneChoice, callbacks: Callbacks) {
            self.writer = writer
            self.mixer = mixer
            self.source = source
            self.microphoneChoice = microphone
            self.callbacks = callbacks
        }
    }

    var isRecording: Bool { active.withLock { $0 != nil } }

    // MARK: - Start / stop

    func start(writingTo url: URL, source: SystemAudioSource, microphone: MicrophoneChoice, callbacks: Callbacks) async throws {
        let result = await perform(on: control, timeout: 10) { [self] in
            Result { try begin(url: url, source: source, microphone: microphone, callbacks: callbacks) }
        }
        guard let result else {
            // `begin` may still finish later; it must not then keep recording on its own.
            control.async { [self] in
                if let session = active.withLock({ $0 }) { abandon(session) }
            }
            throw SessionCaptureError.audioSystemNotResponding
        }
        try result.get()
    }

    /// Stops and closes the file. Never hangs: the hardware gets 3 s to stop and the file 8 s to close —
    /// and a fragmented file is playable even if closing never finishes.
    func stop() async -> Summary {
        guard let session = active.withLock({ (current: inout Session?) -> Session? in
            defer { current = nil }
            return current
        }) else { return Summary() }

        let microphones = await perform(on: control, timeout: 3) { [self] () -> [String] in
            session.supervisor?.cancel()
            stopSystem(session)
            stopMicrophone(session)
            return session.microphonesUsed
        }
        if microphones == nil {
            Log.audio.error("audio hardware did not stop within 3 s; closing the recording anyway")
        }
        let closed = await closeFile(session, timeout: 8)
        if !closed {
            Log.audio.error("the recording did not finish closing in time; the file on disk is still playable")
        }

        var summary = Summary()
        summary.duration = session.writer.duration
        summary.capturedSystemAudio = session.capturedSystemAudio.load(ordering: .relaxed)
        summary.microphones = microphones ?? []
        summary.problem = session.problem.withLock { $0 }
        Log.audio.notice("session recording stopped: \(summary.duration, format: .fixed(precision: 1))s, system audio: \(summary.capturedSystemAudio), voice from: \(summary.microphones.joined(separator: " → "), privacy: .public), late audio dropped: \(Double(session.mixer.droppedLateFrames) / SessionMixer.sampleRate, format: .fixed(precision: 2))s, encoder dropped: \(session.writer.dropped, format: .fixed(precision: 2))s")
        return summary
    }

    /// For quitting: stops if that can happen within `timeout`; if not, the fragments already on disk
    /// stand on their own. Safe to call on the main thread — nothing in `stop()` needs it.
    func stopBlocking(timeout: TimeInterval) -> Summary? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = OSAllocatedUnfairLock<Summary?>(initialState: nil)
        Task.detached { [self] in
            let summary = await stop()
            box.withLock { $0 = summary }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + timeout)
        return box.withLock { $0 }
    }

    /// Takes effect at once when recording.
    func setMicrophone(_ choice: MicrophoneChoice) {
        control.async { [self] in
            guard let session = active.withLock({ $0 }) else { return }
            session.microphoneChoice = choice
            session.pendingMicrophone = nil
            reconcileMicrophone(session, now: Self.nowNanos(), immediately: true)
        }
    }

    // MARK: - Control queue

    private func begin(url: URL, source: SystemAudioSource, microphone: MicrophoneChoice, callbacks: Callbacks) throws {
        guard active.withLock({ $0 }) == nil else { return }
        let writer = try SessionWriter(url: url, format: SessionMixer.format)
        let session = Session(writer: writer, mixer: SessionMixer(originHostTime: AudioGetCurrentHostTime()),
                              source: source, microphone: microphone, callbacks: callbacks)
        buildSystem(session)
        if microphone != .off, let target = desiredMicrophone(session) {
            buildMicrophone(session, device: target)
        }
        guard session.system != nil || session.microphone != nil else {
            writer.cancel()
            throw session.systemProblem ?? SessionCaptureError.noMicrophone
        }
        active.withLock { $0 = session }

        let flusher = DispatchSource.makeTimerSource(queue: writing)
        flusher.schedule(deadline: .now() + Self.flushInterval, repeating: Self.flushInterval)
        flusher.setEventHandler { [weak self] in self?.flush(session, final: false) }
        session.flusher = flusher
        flusher.resume()

        let supervisor = DispatchSource.makeTimerSource(queue: control)
        supervisor.schedule(deadline: .now() + Self.tick, repeating: Self.tick)
        supervisor.setEventHandler { [weak self] in self?.supervise(session) }
        session.supervisor = supervisor
        supervisor.resume()

        Log.audio.notice("session recording started: \(source.displayName, privacy: .public) clocked by \(session.system?.capture.clock.name ?? "nothing yet", privacy: .public), voice from \(session.microphone?.capture.device.name ?? "nobody", privacy: .public)")
    }

    /// Twice a second: rebuild what broke, follow the call's microphone, report.
    private func supervise(_ session: Session) {
        guard active.withLock({ $0 === session }) else { return }
        session.ticks += 1
        let now = Self.nowNanos()
        let churn = churnSeconds > 0 && Double(now - max(session.lastChurn, session.mixer.startNanos)) / 1e9 >= churnSeconds
        if churn { session.lastChurn = now }

        // What the Mac plays.
        if let system = session.system {
            if churn || !system.capture.isIntact || system.input.isStalled(nowNanos: now, after: Self.stallSeconds) {
                Log.audio.notice("system audio: \(churn ? "test rebuild" : "device changed or stopped", privacy: .public); rebuilding")
                stopSystem(session)
                buildSystem(session)
            }
        } else if Double(now - session.lastSystemAttempt) / 1e9 >= 2 {
            buildSystem(session)
        }

        // The user's voice.
        if churn, session.microphone != nil {
            Log.audio.notice("microphone: test rebuild")
            stopMicrophone(session)
        }
        reconcileMicrophone(session, now: now, immediately: churn)

        publish(session, now: now)
    }

    private func reconcileMicrophone(_ session: Session, now: UInt64, immediately: Bool) {
        guard session.microphoneChoice != .off else {
            stopMicrophone(session)
            return
        }
        if let microphone = session.microphone,
           !microphone.capture.isIntact || microphone.input.isStalled(nowNanos: now, after: Self.stallSeconds) {
            Log.audio.notice("microphone \(microphone.capture.device.name, privacy: .public) changed or stopped; reopening")
            stopMicrophone(session)
        }
        // Looking around costs a little; once a second is plenty.
        guard immediately || session.microphone == nil || session.ticks % 2 == 0 else { return }
        guard let target = desiredMicrophone(session) else { return }

        if let current = session.microphone {
            guard current.capture.device.id != target else {
                session.pendingMicrophone = nil
                return
            }
            // Call apps reopen devices while they settle: switch once the new choice holds for two looks.
            if !immediately {
                let looks = session.pendingMicrophone?.id == target ? (session.pendingMicrophone?.looks ?? 0) + 1 : 1
                session.pendingMicrophone = (target, looks)
                guard looks >= 2 else { return }
            }
            session.pendingMicrophone = nil
            Log.audio.notice("microphone: \(current.capture.device.name, privacy: .public) → \(AudioDevices.device(target)?.name ?? "?", privacy: .public)")
            stopMicrophone(session)
        } else if !immediately, Double(now - session.lastMicrophoneAttempt) / 1e9 < 1 {
            return
        }
        buildMicrophone(session, device: target)
    }

    /// The microphone to record: the one picked by hand while it is connected; otherwise the one a call
    /// is using; otherwise the default input — followed when it changes, kept while nothing says to move.
    private func desiredMicrophone(_ session: Session) -> AudioObjectID? {
        if case .device(let uid, _) = session.microphoneChoice, let picked = AudioDevices.device(uid: uid), AudioDevices.isAlive(picked.id) {
            return picked.id
        }
        let defaultInput = AudioDevices.defaultInput
        if let inUse = AudioDevices.microphoneInUse(preferring: session.source.bundleID) {
            session.automaticMicrophone = inUse
        } else if defaultInput != session.lastDefaultInput || !(session.automaticMicrophone.map(AudioDevices.isAlive) ?? false) {
            session.automaticMicrophone = AudioDevices.idleSafeDefaultInput()
        }
        session.lastDefaultInput = defaultInput
        return session.automaticMicrophone
    }

    private func buildSystem(_ session: Session) {
        session.lastSystemAttempt = Self.nowNanos()
        var capture: SystemAudioCapture?
        do {
            let opened = try SystemAudioCapture(source: session.source)
            capture = opened
            guard let input = MixerInput(slot: .system, sampleRate: opened.sampleRate, mixer: session.mixer) else {
                throw SessionCaptureError.aggregateCreationFailed(-1)
            }
            try opened.start(on: systemQueue) { stream, hostTime in input.push(stream, hostTime: hostTime) }
            session.system = (opened, input)
            if session.systemProblem != nil { Log.audio.notice("system audio capture is back") }
            session.systemProblem = nil
            Log.audio.info("system audio: \(session.source.displayName, privacy: .public), clocked by \(opened.clock.name, privacy: .public) at \(opened.sampleRate, format: .fixed(precision: 0)) Hz")
        } catch {
            capture?.stop()
            if session.systemProblem == nil {
                Log.audio.error("system audio capture unavailable: \(error.localizedDescription, privacy: .public)")
            }
            session.systemProblem = error
        }
    }

    private func stopSystem(_ session: Session) {
        guard let system = session.system else { return }
        session.system = nil
        system.capture.stop()
        if system.input.hasHeardSound { session.capturedSystemAudio.store(true, ordering: .relaxed) }
    }

    private func buildMicrophone(_ session: Session, device id: AudioObjectID) {
        session.lastMicrophoneAttempt = Self.nowNanos()
        guard let device = AudioDevices.device(id) else { return }
        var capture: MicrophoneCapture?
        do {
            let opened = try MicrophoneCapture(device: device)
            capture = opened
            guard let input = MixerInput(slot: .microphone, sampleRate: opened.sampleRate, mixer: session.mixer) else {
                throw SessionCaptureError.noMicrophone
            }
            try opened.start(on: microphoneQueue) { stream, hostTime in input.push(stream, hostTime: hostTime) }
            session.microphone = (opened, input)
            if session.microphonesUsed.last != device.name { session.microphonesUsed.append(device.name) }
            Log.audio.notice("recording your voice from \(device.name, privacy: .public) at \(opened.sampleRate, format: .fixed(precision: 0)) Hz")
        } catch {
            capture?.stop()
            Log.audio.error("microphone \(device.name, privacy: .public) could not start: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func stopMicrophone(_ session: Session) {
        guard let microphone = session.microphone else { return }
        session.microphone = nil
        microphone.capture.stop()
    }

    private func publish(_ session: Session, now: UInt64) {
        if session.system?.input.hasHeardSound == true { session.capturedSystemAudio.store(true, ordering: .relaxed) }
        var status = Status()
        status.capturedSystemAudio = session.capturedSystemAudio.load(ordering: .relaxed)
        status.systemAudioProblem = session.system == nil ? session.systemProblem?.localizedDescription : nil
        if let microphone = session.microphone {
            status.microphoneName = microphone.capture.device.name
            status.microphoneSilent = microphone.input.secondsSinceSound(nowNanos: now) > 4
        }
        if status != session.lastStatus {
            session.lastStatus = status
            session.callbacks.onStatus(status)
        }

        // Levels only, every 30 s, for `log stream` when something sounds off.
        let peaks = session.mixer.takePeaks()
        session.peaks = (max(session.peaks.system, peaks.system), max(session.peaks.microphone, peaks.microphone))
        if session.ticks % 60 == 0 {
            Log.audio.info("levels over 30 s: system \(Self.decibels(session.peaks.system), format: .fixed(precision: 0)) dBFS, voice \(Self.decibels(session.peaks.microphone), format: .fixed(precision: 0)) dBFS (\(status.microphoneName ?? "no mic", privacy: .public))")
            session.peaks = (0, 0)
        }
    }

    /// A start that took too long: undo it completely.
    private func abandon(_ session: Session) {
        active.withLock { current in if current === session { current = nil } }
        session.supervisor?.cancel()
        stopSystem(session)
        stopMicrophone(session)
        writing.async {
            session.flusher?.cancel()
            session.mixer.close()
            session.writer.cancel()
        }
    }

    // MARK: - Writing queue

    private func flush(_ session: Session, final: Bool) {
        let target = final ? max(session.mixer.now, session.mixer.end) : session.mixer.now - Self.writeDelay
        while let chunk = session.mixer.take(upTo: target) {
            guard !session.writeFailed else { return }
            do {
                try session.writer.append(chunk)
            } catch {
                session.writeFailed = true
                session.problem.withLock { $0 = error.localizedDescription }
                Log.audio.error("session file write failed: \(error.localizedDescription, privacy: .public)")
                session.callbacks.onWriteFailure(error)
            }
            if !final { return }
        }
    }

    private func closeFile(_ session: Session, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = Once()
            writing.async { [self] in
                session.flusher?.cancel()
                flush(session, final: true)
                session.mixer.close()
                session.writer.finish { error in
                    if let error {
                        session.problem.withLock { $0 = $0 ?? error.localizedDescription }
                        Log.audio.error("closing the recording failed: \(error.localizedDescription, privacy: .public)")
                    }
                    if once.claim() { continuation.resume(returning: error == nil) }
                }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                if once.claim() { continuation.resume(returning: false) }
            }
        }
    }

    // MARK: - Helpers

    /// Runs `work` on `queue` and waits for it, but never longer than `timeout`. Nil if it did not finish in time.
    private func perform<T: Sendable>(on queue: DispatchQueue, timeout: TimeInterval, _ work: @escaping @Sendable () -> T) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let once = Once()
            queue.async {
                let value = work()
                if once.claim() { continuation.resume(returning: value) }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                if once.claim() { continuation.resume(returning: nil) }
            }
        }
    }

    private static func nowNanos() -> UInt64 {
        AudioConvertHostTimeToNanos(AudioGetCurrentHostTime())
    }

    private static func decibels(_ peak: Float) -> Double {
        peak > 0 ? 20 * log10(Double(peak)) : -120
    }
}

/// True for the first caller only.
nonisolated private final class Once: Sendable {
    private let done = Atomic<Bool>(false)

    func claim() -> Bool {
        !done.exchange(true, ordering: .acquiringAndReleasing)
    }
}
