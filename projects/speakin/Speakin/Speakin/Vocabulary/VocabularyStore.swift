//
//  VocabularyStore.swift
//  Speakin
//
//  The names the speech model should know. Gathered automatically from the Mac — project folders,
//  Xcode projects, installed apps, macOS learned spellings, the user's name — plus whatever the
//  user teaches by correcting a transcription. Persisted next to the transcriptions.
//

import AppKit
import Combine
import Foundation
import os

@MainActor
final class VocabularyStore: ObservableObject {
    enum Source: String, Codable, CaseIterable, Sendable {
        case learned, manual, spelling, apps, projects, user

        var label: String {
            switch self {
            case .learned: "Learned from your corrections"
            case .manual: "Added by you"
            case .spelling: "macOS learned spellings"
            case .apps: "Installed apps"
            case .projects: "Project folders"
            case .user: "Your name"
            }
        }
    }

    struct Entry: Identifiable, Hashable, Codable, Sendable {
        let text: String
        let source: Source
        var id: String { text.lowercased() }
    }

    private struct Persisted: Codable {
        var manual: [String] = []
        var learned: [String] = []
        var corrections: [String: String] = [:]
        var ignored: [String] = []
        var harvested: [Entry] = []
        var lastScan: Date?
    }

    @Published private(set) var entries: [Entry] = []
    /// `Phonetics.letters` of a misheard phrase → the spelling the user wants.
    @Published private(set) var corrections: [String: String] = [:]
    @Published private(set) var ignored: Set<String> = []
    @Published private(set) var lastScan: Date?
    @Published private(set) var isScanning = false

    private let fileURL: URL
    private var persisted = Persisted()
    private let oracle = WordOracle.shared

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("vocabulary.json")
    }

    /// Active terms: everything not ignored, learned/manual first.
    var terms: [VocabularyTerm] {
        entries.filter { !ignored.contains($0.id) }.map { VocabularyTerm($0.text) }
    }

    var contextualStrings: [String] {
        entries.filter { !ignored.contains($0.id) }.map(\.text)
    }

    // MARK: - Persistence

    func load() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder.speakin.decode(Persisted.self, from: data) {
            persisted = decoded
        }
        corrections = persisted.corrections
        ignored = Set(persisted.ignored)
        lastScan = persisted.lastScan
        rebuildEntries(harvested: persisted.harvested)
    }

    private func save() {
        persisted.corrections = corrections
        persisted.ignored = Array(ignored).sorted()
        persisted.lastScan = lastScan
        do {
            try JSONEncoder.speakin.encode(persisted).write(to: fileURL, options: .atomic)
        } catch {
            Log.store.error("vocabulary save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func rebuildEntries(harvested: [Entry]) {
        var seen = Set<String>()
        var result: [Entry] = []
        let ordered = persisted.learned.map { Entry(text: $0, source: .learned) }
            + persisted.manual.map { Entry(text: $0, source: .manual) }
            + harvested
        for entry in ordered where seen.insert(entry.id).inserted {
            result.append(entry)
        }
        entries = result
    }

    // MARK: - Teaching

    func addManual(_ word: String) {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        ignored.remove(trimmed.lowercased())
        if !persisted.manual.contains(where: { $0.lowercased() == trimmed.lowercased() }) {
            persisted.manual.append(trimmed)
        }
        rebuildEntries(harvested: persisted.harvested)
        save()
    }

    /// Harvested entries are hidden (they would come back on the next scan otherwise); learned and
    /// manual ones are deleted.
    func remove(_ entry: Entry) {
        switch entry.source {
        case .learned: persisted.learned.removeAll { $0.lowercased() == entry.id }
        case .manual: persisted.manual.removeAll { $0.lowercased() == entry.id }
        default: ignored.insert(entry.id)
        }
        rebuildEntries(harvested: persisted.harvested)
        save()
    }

    func unhide(_ id: String) {
        ignored.remove(id)
        save()
    }

    func removeCorrection(heard: String) {
        corrections.removeValue(forKey: heard)
        save()
    }

    /// Learns from an edited transcription. Returns the corrections that were recorded.
    @discardableResult
    func learn(from changes: [TranscriptDiff.Change]) -> [TranscriptDiff.Change] {
        var recorded: [TranscriptDiff.Change] = []
        for change in changes {
            let heardKey = Phonetics.letters(change.heard)
            guard heardKey.count >= 3, !change.corrected.isEmpty else { continue }
            let correctedWords = TranscriptDiff.words(in: change.corrected)
            // Only spellings that look like names are worth remembering; "teh" → "the" is not our job.
            let coined = correctedWords.filter { oracle.isCoinedWord($0) || ($0.first?.isUppercase == true && $0.count >= 3) }
            guard !coined.isEmpty else { continue }
            corrections[heardKey] = change.corrected
            for word in coined where !persisted.learned.contains(where: { $0.lowercased() == word.lowercased() }) {
                persisted.learned.append(word)
                ignored.remove(word.lowercased())
            }
            recorded.append(change)
        }
        if !recorded.isEmpty {
            rebuildEntries(harvested: persisted.harvested)
            save()
            Log.speech.info("learned \(recorded.count) correction(s): \(recorded.map { "\($0.heard) → \($0.corrected)" }.joined(separator: ", "), privacy: .public)")
        }
        return recorded
    }

    // MARK: - Harvesting

    /// Scans at most once a day unless forced; the previous result is used meanwhile.
    func rescanIfStale() async {
        if let lastScan, Date().timeIntervalSince(lastScan) < 24 * 3600, !persisted.harvested.isEmpty { return }
        await rescan()
    }

    func rescan() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        let started = Date()
        let raw = await Task.detached(priority: .userInitiated) { Harvester.collect() }.value
        let harvestSeconds = Date().timeIntervalSince(started)

        var harvested: [Entry] = []
        var seen = Set<String>()
        for candidate in raw {
            guard let text = normalize(candidate) else { continue }
            let key = text.lowercased()
            guard seen.insert(key).inserted else { continue }
            harvested.append(Entry(text: text, source: candidate.source))
        }
        persisted.harvested = harvested
        lastScan = Date()
        rebuildEntries(harvested: harvested)
        save()
        Log.store.info("vocabulary scan: \(harvested.count) terms from \(raw.count) candidates in \(Date().timeIntervalSince(started), format: .fixed(precision: 2))s (walk \(harvestSeconds, format: .fixed(precision: 2))s) — \(Dictionary(grouping: harvested, by: \.source).map { "\($0.key.rawValue): \($0.value.count)" }.sorted().joined(separator: ", "), privacy: .public)")
    }

    private func normalize(_ candidate: Harvester.Candidate) -> String? {
        let letters = Phonetics.letters(candidate.text)
        guard letters.count >= 3, letters.contains(where: \.isLetter), !letters.allSatisfy(\.isNumber) else { return nil }
        guard oracle.isCoinedWord(candidate.text) else { return nil }
        if candidate.capitalize, let first = candidate.text.first, first.isLowercase {
            return first.uppercased() + candidate.text.dropFirst()
        }
        return candidate.text
    }

    /// Runs off the main thread; returns raw candidates, filtered later by the oracle.
    nonisolated enum Harvester {
        struct Candidate: Sendable {
            let text: String
            let source: Source
            let capitalize: Bool
        }

        static func collect() -> [Candidate] {
            var out: [Candidate] = []
            let fm = FileManager.default
            let home = fm.homeDirectoryForCurrentUser

            // Learned spellings (System Settings / "Learn Spelling" anywhere).
            let dictionary = home.appendingPathComponent("Library/Spelling/LocalDictionary")
            if let text = try? String(contentsOf: dictionary, encoding: .utf8) {
                for line in text.split(whereSeparator: \.isNewline) {
                    let word = line.trimmingCharacters(in: .whitespaces)
                    if !word.isEmpty { out.append(Candidate(text: word, source: .spelling, capitalize: false)) }
                }
            }

            // The user's own name.
            for part in NSFullUserName().split(separator: " ") {
                out.append(Candidate(text: String(part), source: .user, capitalize: false))
            }

            // Installed apps.
            for folder in ["/Applications", "/Applications/Utilities", home.appendingPathComponent("Applications").path] {
                for item in (try? fm.contentsOfDirectory(atPath: folder)) ?? [] where item.hasSuffix(".app") {
                    let name = String(item.dropLast(4))
                    for part in name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" }) {
                        out.append(Candidate(text: String(part), source: .apps, capitalize: false))
                    }
                }
            }

            // Project folders: any folder that holds several repositories or Xcode projects.
            for root in projectRoots(home: home) {
                for project in subdirectories(of: root) {
                    for part in project.lastPathComponent.split(whereSeparator: { "-_ .".contains($0) }) {
                        out.append(Candidate(text: String(part), source: .projects, capitalize: true))
                    }
                    for name in xcodeProjectNames(in: project) {
                        out.append(Candidate(text: name, source: .projects, capitalize: false))
                    }
                }
            }
            return out
        }

        // Documents/Desktop/Downloads are skipped on purpose: reading them makes macOS ask for permission.
        private static let skippedHomeFolders: Set<String> = [
            "Library", "Applications", "Music", "Movies", "Pictures", "Public", "Downloads", "Desktop", "Documents",
        ]
        private static let maxChildrenToInspect = 80
        private static let markers = [".git", "package.json", "Package.swift", "Cargo.toml", "pyproject.toml", "go.mod"]

        private static func projectRoots(home: URL) -> [URL] {
            var roots: [URL] = []
            var candidates = ["Projects", "Developer", "Code", "code", "src", "dev", "work", "Work", "repos", "Repos"]
                .map { home.appendingPathComponent($0) }
            for level1 in subdirectories(of: home) where !skippedHomeFolders.contains(level1.lastPathComponent) {
                candidates.append(level1)
                let children = subdirectories(of: level1)
                if children.count <= maxChildrenToInspect { candidates.append(contentsOf: children) }
            }
            var seen = Set<String>()
            for candidate in candidates where seen.insert(candidate.path).inserted {
                let children = subdirectories(of: candidate)
                guard children.count <= 400 else { continue }
                let projects = children.prefix(maxChildrenToInspect).filter(looksLikeProject)
                if projects.count >= 3 { roots.append(candidate) }
            }
            return roots
        }

        private static func looksLikeProject(_ url: URL) -> Bool {
            let fm = FileManager.default
            if markers.contains(where: { fm.fileExists(atPath: url.appendingPathComponent($0).path) }) { return true }
            return ((try? fm.contentsOfDirectory(atPath: url.path)) ?? []).contains { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }
        }

        private static func xcodeProjectNames(in project: URL) -> [String] {
            var names: [String] = []
            var folders = [project]
            folders.append(contentsOf: subdirectories(of: project).prefix(30))
            for folder in folders {
                for item in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
                    if item.hasSuffix(".xcodeproj") { names.append(String(item.dropLast(10))) }
                }
            }
            return names
        }

        private static func subdirectories(of url: URL) -> [URL] {
            let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                                                        options: [.skipsHiddenFiles])) ?? []
            return items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        }
    }
}

extension JSONEncoder {
    nonisolated static var speakin: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

extension JSONDecoder {
    nonisolated static var speakin: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
