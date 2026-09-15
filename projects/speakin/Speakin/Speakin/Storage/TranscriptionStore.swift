//
//  TranscriptionStore.swift
//  Speakin
//
//  On-disk history. One JSON file per transcription (written atomically) plus the WAV it came
//  from, under ~/Library/Application Support/Speakin. Nothing is ever overwritten in place, and
//  audio that has no record yet is adopted as a pending transcription on load.
//

import Combine
import Foundation

nonisolated struct TranscriptionRecord: Codable, Identifiable, Hashable, Sendable {
    enum Status: String, Codable, Sendable {
        case recording      // capture in progress (or the app died while capturing)
        case pending        // audio on disk, not transcribed yet
        case transcribing   // model running (or the app died while it ran)
        case completed
        case failed
    }

    var id: String
    var createdAt: Date
    var updatedAt: Date
    var duration: TimeInterval
    var status: Status
    var text: String
    /// The model's verbatim output when `text` was cleaned up (filler words removed); nil otherwise.
    var rawText: String?
    var error: String?
    var localeIdentifier: String?
    var engine: String?
    var audioFileName: String?
    var pasted: Bool

    var hasAudio: Bool { audioFileName != nil }

    /// True when there is audio that still deserves a (re)try.
    var needsTranscription: Bool { status != .completed && hasAudio }

    var preview: String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return status == .completed ? "(nothing heard)" : "(\(status.rawValue))" }
        return trimmed.count > 90 ? String(trimmed.prefix(90)) + "…" : trimmed
    }

    static func makeID(date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = String(UUID().uuidString.prefix(6)).lowercased()
        return "\(f.string(from: date))-\(suffix)"
    }
}

@MainActor
final class TranscriptionStore: ObservableObject {
    static let maxRecordings = 30
    static let maxTranscriptions = 1000

    let rootURL: URL
    let recordingsURL: URL
    let transcriptionsURL: URL

    /// Newest first.
    @Published private(set) var records: [TranscriptionRecord] = []

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init(rootURL: URL? = nil) throws {
        let base = rootURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Speakin", isDirectory: true)
        self.rootURL = base
        recordingsURL = base.appendingPathComponent("recordings", isDirectory: true)
        transcriptionsURL = base.appendingPathComponent("transcriptions", isDirectory: true)
        for url in [recordingsURL, transcriptionsURL] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    // MARK: - Paths

    func audioURL(for record: TranscriptionRecord) -> URL? {
        guard let name = record.audioFileName else { return nil }
        let url = recordingsURL.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func newAudioURL(id: String) -> URL {
        recordingsURL.appendingPathComponent("\(id).wav")
    }

    private func recordURL(id: String) -> URL {
        transcriptionsURL.appendingPathComponent("\(id).json")
    }

    // MARK: - Loading

    func load() {
        var loaded: [TranscriptionRecord] = []
        let fm = FileManager.default
        let jsonFiles = (try? fm.contentsOfDirectory(at: transcriptionsURL, includingPropertiesForKeys: nil)) ?? []
        for url in jsonFiles where url.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: url)
                var record = try decoder.decode(TranscriptionRecord.self, from: data)
                // Drop references to audio the retention pass already removed.
                if let name = record.audioFileName,
                   !fm.fileExists(atPath: recordingsURL.appendingPathComponent(name).path) {
                    record.audioFileName = nil
                }
                loaded.append(record)
            } catch {
                NSLog("Speakin: skipping unreadable record \(url.lastPathComponent): \(error)")
            }
        }

        // Audio without a record (should not happen, but a speech is never thrown away).
        let known = Set(loaded.compactMap(\.audioFileName))
        let wavFiles = (try? fm.contentsOfDirectory(at: recordingsURL, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for url in wavFiles where url.pathExtension == "wav" && !known.contains(url.lastPathComponent) {
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            let id = url.deletingPathExtension().lastPathComponent
            let record = TranscriptionRecord(id: id, createdAt: created, updatedAt: Date(), duration: 0,
                                             status: .pending, text: "", rawText: nil, error: nil, localeIdentifier: nil,
                                             engine: nil, audioFileName: url.lastPathComponent, pasted: false)
            loaded.append(record)
            write(record)
        }

        records = loaded.sorted { $0.createdAt > $1.createdAt }
    }

    func record(withID id: String) -> TranscriptionRecord? {
        records.first { $0.id == id }
    }

    // MARK: - Writing

    func save(_ record: TranscriptionRecord) {
        var record = record
        record.updatedAt = Date()
        write(record)
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
            records.sort { $0.createdAt > $1.createdAt }
        }
    }

    private func write(_ record: TranscriptionRecord) {
        do {
            let data = try encoder.encode(record)
            try data.write(to: recordURL(id: record.id), options: .atomic)
        } catch {
            NSLog("Speakin: failed to write record \(record.id): \(error)")
        }
    }

    func delete(_ record: TranscriptionRecord) {
        let fm = FileManager.default
        try? fm.removeItem(at: recordURL(id: record.id))
        if let name = record.audioFileName {
            try? fm.removeItem(at: recordingsURL.appendingPathComponent(name))
        }
        records.removeAll { $0.id == record.id }
    }

    /// Keeps the newest `maxTranscriptions` records and the audio of the newest `maxRecordings`.
    func enforceRetention() {
        let sorted = records.sorted { $0.createdAt > $1.createdAt }
        for record in sorted.dropFirst(Self.maxTranscriptions) {
            delete(record)
        }
        let withAudio = sorted.prefix(Self.maxTranscriptions).filter(\.hasAudio)
        for var record in withAudio.dropFirst(Self.maxRecordings) {
            if let name = record.audioFileName {
                try? FileManager.default.removeItem(at: recordingsURL.appendingPathComponent(name))
            }
            record.audioFileName = nil
            save(record)
        }
    }
}
