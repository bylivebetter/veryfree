//
//  TranscriptDiff.swift
//  Speakin
//
//  Word-level diff between a transcription and the user's corrected version, so a single edit
//  ("knockups" → "Nocaps") can be learned.
//

import Foundation

nonisolated enum TranscriptDiff {
    struct Change: Equatable, Sendable {
        let heard: String
        let corrected: String
    }

    /// Replaced runs of words (insertions and deletions alone are ignored).
    static func changes(from old: String, to new: String, maxHeardWords: Int = 4, maxCorrectedWords: Int = 3) -> [Change] {
        let a = words(in: old)
        let b = words(in: new)
        guard !a.isEmpty, !b.isEmpty, a.count * b.count <= 4_000_000 else { return [] }

        // Longest common subsequence table over the word sequences.
        var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }

        var changes: [Change] = []
        var i = 0, j = 0
        var removed: [String] = [], added: [String] = []
        func flush() {
            if !removed.isEmpty, !added.isEmpty,
               removed.count <= maxHeardWords, added.count <= maxCorrectedWords {
                changes.append(Change(heard: removed.joined(separator: " "), corrected: added.joined(separator: " ")))
            }
            removed.removeAll()
            added.removeAll()
        }
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                flush()
                i += 1; j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                removed.append(a[i]); i += 1
            } else {
                added.append(b[j]); j += 1
            }
        }
        while i < a.count { removed.append(a[i]); i += 1 }
        while j < b.count { added.append(b[j]); j += 1 }
        flush()
        return changes
    }

    static func words(in text: String) -> [String] {
        var result: [String] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byWords, .localized]) { sub, _, _, _ in
            if let sub, !sub.isEmpty { result.append(sub) }
        }
        return result
    }
}
