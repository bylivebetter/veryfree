// Dev probe: exercises the mic → converter → WAV → live-transcription path on an audio file,
// then the crash-recovery (file) path. Build with Tools/probe/run.sh.

import AVFoundation
import Foundation
import Speech

@main
struct Probe {
    static func main() async {
        setvbuf(stdout, nil, _IONBF, 0)
        do {
            try await run()
        } catch {
            print("!! failed: \(error)")
            exit(1)
        }
    }

    static func run() async throws {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            print("usage: probe <audio-file> [locale]")
            exit(2)
        }
        let inputURL = URL(fileURLWithPath: args[1])
        let wanted = Locale(identifier: args.count >= 3 ? args[2] : "en-US")

        let t0 = Date()
        func stamp(_ label: String) { print(String(format: "[%6.2fs] %@", Date().timeIntervalSince(t0), label)) }

        let options = await SpeechEngine.availableOptions()
        stamp("available locales: \(options.count) (speech: \(options.filter { $0.kind == .speechTranscriber }.count), dictation-only: \(options.filter { $0.kind == .dictationTranscriber }.count))")
        print("   e.g. " + options.prefix(12).map { "\($0.locale.identifier)/\($0.kind == .speechTranscriber ? "S" : "D")" }.joined(separator: " "))

        guard let resolved = await SpeechEngine.resolve(preferred: wanted) else {
            print("!! no module supports \(wanted.identifier)")
            exit(1)
        }
        stamp("resolved \(wanted.identifier) -> \(resolved.locale.identifier) via \(resolved.kind.displayName)")

        let engine = SpeechEngine(locale: resolved.locale, kind: resolved.kind)
        stamp("asset status: \(await engine.assetStatus())")
        try await engine.ensureAssets { p in print(String(format: "   download %.0f%%", p * 100)) }
        stamp("assets ready")

        let canonical = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        try await engine.warmUp(inputFormat: canonical)
        stamp("warmed up")

        // ---- Live path, simulating the microphone tap ----
        let file = try AVAudioFile(forReading: inputURL)
        let native = file.processingFormat
        stamp("input: \(native.sampleRate) Hz, \(native.channelCount) ch, \(file.length) frames (\(String(format: "%.1f", Double(file.length) / native.sampleRate)) s)")
        guard let toCanonical = AudioFormatConverter(from: native, to: canonical) else {
            print("!! cannot build converter"); exit(1)
        }
        let wavURL = inputURL.deletingLastPathComponent().appendingPathComponent("probe-live.wav")
        let writer = try WAVWriter(url: wavURL, sampleRate: 16_000, channels: 1)
        let session = try await engine.startLiveSession(inputFormat: canonical)
        stamp("live session started")

        var fed = 0
        var peak: Float = 0
        while file.framePosition < file.length {
            guard let chunk = AVAudioPCMBuffer(pcmFormat: native, frameCapacity: 4096) else { break }
            do { try file.read(into: chunk, frameCount: 4096) } catch { print("!! read #\(fed) failed: \(error)"); throw error }
            if chunk.frameLength == 0 { break }
            guard let converted = toCanonical.convert(chunk) else { print("   (chunk #\(fed) produced no output)"); continue }
            peak = max(peak, converted.speakin_rmsLevel)
            do { try writer.append(converted) } catch { print("!! append #\(fed) failed: \(error)"); throw error }
            session.feed(converted)
            fed += 1
        }
        let duration = try writer.close()
        stamp("fed \(fed) chunks, wrote \(String(format: "%.1f", duration)) s wav, peak rms \(String(format: "%.2f", peak)), preview so far: \"\(session.previewText.prefix(60))…\"")

        let tFinish = Date()
        let liveText = try await session.finish()
        stamp("finish() took \(String(format: "%.2f", Date().timeIntervalSince(tFinish))) s")
        print("LIVE  : \(liveText)")

        // ---- Recovery path: simulate a crash (zeroed header sizes), repair, transcribe from file ----
        let crashedURL = inputURL.deletingLastPathComponent().appendingPathComponent("probe-crashed.wav")
        try? FileManager.default.removeItem(at: crashedURL)
        try FileManager.default.copyItem(at: wavURL, to: crashedURL)
        let h = try FileHandle(forUpdating: crashedURL)
        try h.seek(toOffset: 0)
        try h.write(contentsOf: WAVWriter.header(sampleRate: 16_000, channels: 1, dataBytes: 0))
        try h.close()
        let repaired = try WAVWriter.repairHeader(at: crashedURL)
        stamp("header repaired: \(repaired)")
        let tFile = Date()
        let fileText = try await engine.transcribe(fileAt: crashedURL)
        stamp("file transcription took \(String(format: "%.2f", Date().timeIntervalSince(tFile))) s")
        print("FILE  : \(fileText)")

        // Second live session to verify the model is retained (should start instantly).
        let tSecond = Date()
        let second = try await engine.startLiveSession(inputFormat: canonical)
        stamp("second live session start took \(String(format: "%.2f", Date().timeIntervalSince(tSecond))) s")
        await second.cancel()
        stamp("done")
    }
}
