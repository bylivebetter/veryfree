//
//  VocabularyFixer.swift
//  Speakin
//
//  Rewrites misheard names using the user's vocabulary.
//    1. learned corrections ("knockups" → "Nocaps", taught by editing a transcription) — always;
//    2. exact matches with the wrong casing ("nocaps" → "Nocaps");
//    3. phonetic near-misses that are not real words ("Cuddo" → "Kuddo") — safe to replace outright;
//    4. multi-word phrases spelled exactly like a term ("no caps" → "Nocaps") — unless every word is an
//       everyday word ("to text"), in which case only a learned correction may rewrite it;
//    5. near-misses that ARE real words ("speaking" ~ "Speakin") — reported as candidates only. Apple's
//       on-device language model was evaluated for these and judged wrong too often to be trusted.
//

import Foundation

nonisolated struct VocabularyTerm: Hashable, Sendable {
    let text: String
    let letters: String
    let key: String

    init(_ text: String) {
        self.text = text
        letters = Phonetics.letters(text)
        key = Phonetics.key(text)
    }
}

nonisolated struct VocabularyFixer: Sendable {
    struct Candidate: Hashable, Sendable {
        let heard: String
        let term: String
    }

    struct Result: Sendable {
        var text: String
        var replacements: [(heard: String, term: String)] = []
        var candidates: [Candidate] = []
    }

    let terms: [VocabularyTerm]
    /// `Phonetics.letters` of the misheard phrase → replacement, learned from the user's edits.
    let corrections: [String: String]
    let isRealWord: @Sendable (String) -> Bool
    /// Phrases made only of everyday words ("to text", "live now") are never rewritten on their own;
    /// they need a learned correction.
    let isCommonPhrase: @Sendable ([String]) -> Bool

    private static let maxPhraseWords = 3

    func fix(_ text: String) -> Result {
        var result = Result(text: text)
        guard !terms.isEmpty || !corrections.isEmpty else { return result }

        let tokens = Self.tokens(in: text)
        var edits: [(Range<String.Index>, String)] = []
        var i = 0
        while i < tokens.count {
            var consumed = 0
            for n in stride(from: min(Self.maxPhraseWords, tokens.count - i), through: 1, by: -1) {
                let slice = tokens[i..<(i + n)]
                guard Self.adjacent(slice, in: text) else { continue }
                let phrase = slice.map(\.word).joined(separator: " ")
                let letters = Phonetics.letters(phrase)
                guard letters.count >= 3, letters.contains(where: \.isLetter) else { continue }
                let range = slice.first!.range.lowerBound..<slice.last!.range.upperBound

                if let learned = corrections[letters] {
                    if learned != phrase { edits.append((range, learned)); result.replacements.append((phrase, learned)) }
                    consumed = n
                    break
                }
                if let exact = terms.first(where: { $0.letters == letters }) {
                    if n == 1 || !isCommonPhrase(slice.map(\.word)) {
                        if exact.text != phrase { edits.append((range, exact.text)); result.replacements.append((phrase, exact.text)) }
                    } else {
                        result.candidates.append(Candidate(heard: phrase, term: exact.text))
                    }
                    consumed = n
                    break
                }
                if let near = nearest(letters: letters) {
                    let allReal = slice.allSatisfy { isRealWord($0.word) }
                    if !allReal, near.strong {
                        edits.append((range, near.term.text))
                        result.replacements.append((phrase, near.term.text))
                    } else if allReal || near.strong {
                        result.candidates.append(Candidate(heard: phrase, term: near.term.text))
                    } else {
                        continue
                    }
                    consumed = n
                    break
                }
            }
            i += max(consumed, 1)
        }

        var output = text
        for (range, replacement) in edits.reversed() {
            output.replaceSubrange(range, with: replacement)
        }
        result.text = output
        return result
    }

    /// Best-sounding term for a phrase. `strong` = safe to apply without asking anyone.
    private func nearest(letters: String) -> (term: VocabularyTerm, strong: Bool)? {
        let key = Phonetics.key(letters)
        var best: (VocabularyTerm, Double, Bool)?
        for term in terms {
            let similarity = Phonetics.similarity(letters, term.letters)
            let sameKey = !key.isEmpty && key == term.key
            let strong = sameKey && (key.count >= 3 || similarity >= 0.6)
            let plausible = strong || (sameKey && similarity >= 0.5) || similarity >= 0.8
            guard plausible else { continue }
            let score = similarity + (sameKey ? 0.5 : 0)
            if best == nil || score > best!.1 { best = (term, score, strong) }
        }
        guard let best else { return nil }
        return (best.0, best.2)
    }

    // MARK: - Tokens

    struct Token {
        let word: String
        let range: Range<String.Index>
    }

    static func tokens(in text: String) -> [Token] {
        var tokens: [Token] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byWords, .localized]) { sub, range, _, _ in
            if let sub, !sub.isEmpty { tokens.append(Token(word: sub, range: range)) }
        }
        return tokens
    }

    /// True when only spaces separate the tokens (no punctuation or line breaks).
    private static func adjacent(_ slice: ArraySlice<Token>, in text: String) -> Bool {
        guard slice.count > 1 else { return true }
        var previous = slice.first!
        for token in slice.dropFirst() {
            let gap = text[previous.range.upperBound..<token.range.lowerBound]
            if gap.contains(where: { $0 != " " }) { return false }
            previous = token
        }
        return true
    }

    /// Sentences (with their trailing delimiter and whitespace) as ranges, for the language-model stage.
    static func sentenceRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start = text.startIndex
        var index = text.startIndex
        let enders: Set<Character> = [".", "!", "?", "…", "\n"]
        while index < text.endIndex {
            if enders.contains(text[index]) {
                var end = text.index(after: index)
                while end < text.endIndex, text[end] == " " || enders.contains(text[end]) { end = text.index(after: end) }
                ranges.append(start..<end)
                start = end
                index = end
            } else {
                index = text.index(after: index)
            }
        }
        if start < text.endIndex { ranges.append(start..<text.endIndex) }
        return ranges
    }
}
