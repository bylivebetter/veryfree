//
//  SessionStore.swift
//  Speakin
//
//  Recorded sessions live in a folder you can open in Finder (~/Music/Speakin by default) as plain
//  .m4a files, with the transcript beside them as .txt. Bookkeeping lives in Application Support so
//  the folder stays clean.
//

@preconcurrency import AVFoundation
import AppKit
import Combine
import Foundation
import os

nonisolated struct SessionRecord: Identifiable, Hashable, Codable, Sendable {
    enum Status: String, Codable, Sendable {
        case recording      // in progress, or the app died mid-recording
        case completed
        case failed
    }

    enum TranscriptStatus: String, Codable, Sendable {
        case none, pending, running, done, failed
        /// Transcribed, but nobody said anything: no .txt is written.
        case empty
    }

    var id: String
    var fileName: String
    var createdAt: Date
    var duration: TimeInterval
    var status: Status
    var sourceName: String
    var bundleID: String?
    var includedMicrophone: Bool
    var capturedSystemAudio: Bool
    var transcriptStatus: TranscriptStatus
    var transcriptFileName: String?
    var error: String?
    /// The microphone(s) the voice was recorded from, e.g. "MacBook Pro Microphone → AirPods Pro".
    var microphoneName: String? = nil

    var displayName: String {
        (fileName as NSString).deletingPathExtension
    }
}

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [SessionRecord] = []
    @Published private(set) var folderURL: URL

    private let metadataURL: URL
    private var metadata: [String: SessionRecord] = [:]

    init(supportDirectory: URL, folderURL: URL) {
        self.folderURL = folderURL
        metadataURL = supportDirectory.appendingPathComponent("sessions.json")
    }

    // MARK: - Folder

    static func defaultFolder() -> URL {
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music")
        return music.appendingPathComponent("Speakin", isDirectory: true)
    }

    @discardableResult
    func ensureFolder() -> Bool {
        do {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            return true
        } catch {
            Log.store.error("cannot create sessions folder: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func setFolder(_ url: URL) {
        folderURL = url
        ensureFolder()
        refresh()
    }

    func fileURL(for session: SessionRecord) -> URL {
        folderURL.appendingPathComponent(session.fileName)
    }

    func transcriptURL(for session: SessionRecord) -> URL? {
        guard let name = session.transcriptFileName else { return nil }
        let url = folderURL.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func transcript(for session: SessionRecord) -> String? {
        guard let url = transcriptURL(for: session) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    func fileSize(for session: SessionRecord) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL(for: session).path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// A new file name like "2026-11-20 14-05 Zoom.m4a" — sortable, and readable in Finder.
    func newFileName(source: SystemAudioSource, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm"
        var base = formatter.string(from: date)
        if case .app(_, let name) = source {
            let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            base += " \(safe)"
        }
        var candidate = "\(base).m4a"
        var suffix = 2
        while FileManager.default.fileExists(atPath: folderURL.appendingPathComponent(candidate).path) {
            candidate = "\(base) (\(suffix)).m4a"
            suffix += 1
        }
        return candidate
    }

    // MARK: - Loading

    func load() {
        if let data = try? Data(contentsOf: metadataURL),
           let decoded = try? JSONDecoder.speakin.decode([String: SessionRecord].self, from: data) {
            metadata = decoded
        }
        refresh()
    }

    /// Rebuilds the list from the folder: files are the truth, metadata only decorates them.
    func refresh() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey])) ?? []
        var result: [SessionRecord] = []
        var seen = Set<String>()

        for url in files where url.pathExtension.lowercased() == "m4a" {
            let name = url.lastPathComponent
            seen.insert(name)
            if var record = metadata.values.first(where: { $0.fileName == name }) {
                // The app died while recording: the fragments on disk are still a usable file.
                if record.status == .recording {
                    record.status = .completed
                    record.duration = Self.duration(of: url)
                    if record.transcriptStatus == .running || record.transcriptStatus == .pending {
                        record.transcriptStatus = .pending
                    }
                    metadata[record.id] = record
                }
                if record.duration == 0 { record.duration = Self.duration(of: url) }
                if let transcriptName = record.transcriptFileName,
                   !fm.fileExists(atPath: folderURL.appendingPathComponent(transcriptName).path) {
                    record.transcriptFileName = nil
                    if record.transcriptStatus == .done { record.transcriptStatus = .none }
                }
                result.append(record)
            } else {
                // A file that arrived without us (restored from a backup, renamed, copied in).
                let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
                let transcriptName = (name as NSString).deletingPathExtension + ".txt"
                let hasTranscript = fm.fileExists(atPath: folderURL.appendingPathComponent(transcriptName).path)
                let record = SessionRecord(id: UUID().uuidString, fileName: name, createdAt: created,
                                           duration: Self.duration(of: url), status: .completed,
                                           sourceName: "Unknown", bundleID: nil, includedMicrophone: false,
                                           capturedSystemAudio: true,
                                           transcriptStatus: hasTranscript ? .done : .none,
                                           transcriptFileName: hasTranscript ? transcriptName : nil, error: nil)
                metadata[record.id] = record
                result.append(record)
            }
        }
        // Metadata for files the user deleted in Finder.
        for (id, record) in metadata where !seen.contains(record.fileName) {
            metadata.removeValue(forKey: id)
        }
        sessions = result.sorted { $0.createdAt > $1.createdAt }
        save()
    }

    private static func duration(of url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        let rate = file.processingFormat.sampleRate
        return rate > 0 ? Double(file.length) / rate : 0
    }

    // MARK: - Writing

    func save(_ record: SessionRecord) {
        metadata[record.id] = record
        if let index = sessions.firstIndex(where: { $0.id == record.id }) {
            sessions[index] = record
        } else {
            sessions.append(record)
            sessions.sort { $0.createdAt > $1.createdAt }
        }
        save()
    }

    func saveTranscript(_ text: String, for record: SessionRecord) -> SessionRecord {
        var record = record
        let name = (record.fileName as NSString).deletingPathExtension + ".txt"
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // An empty .txt beside the recording would only look like a failure.
            try? FileManager.default.removeItem(at: folderURL.appendingPathComponent(name))
            record.transcriptFileName = nil
            record.transcriptStatus = .empty
            save(record)
            return record
        }
        do {
            try text.write(to: folderURL.appendingPathComponent(name), atomically: true, encoding: .utf8)
            record.transcriptFileName = name
            record.transcriptStatus = .done
        } catch {
            record.transcriptStatus = .failed
            record.error = error.localizedDescription
            Log.store.error("transcript write failed: \(error.localizedDescription, privacy: .public)")
        }
        save(record)
        return record
    }

    private func save() {
        do {
            try JSONEncoder.speakin.encode(metadata).write(to: metadataURL, options: .atomic)
        } catch {
            Log.store.error("sessions metadata save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Moves the recording (and its transcript) to the Trash — recoverable, unlike a delete.
    func trash(_ record: SessionRecord) {
        let fm = FileManager.default
        try? fm.trashItem(at: fileURL(for: record), resultingItemURL: nil)
        if let transcript = transcriptURL(for: record) { try? fm.trashItem(at: transcript, resultingItemURL: nil) }
        metadata.removeValue(forKey: record.id)
        sessions.removeAll { $0.id == record.id }
        save()
    }

    func reveal(_ record: SessionRecord) {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL(for: record)])
    }

    func open(_ record: SessionRecord) {
        NSWorkspace.shared.open(fileURL(for: record))
    }

    func openFolder() {
        ensureFolder()
        NSWorkspace.shared.open(folderURL)
    }
}
