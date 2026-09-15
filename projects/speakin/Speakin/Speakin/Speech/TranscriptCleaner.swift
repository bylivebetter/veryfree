//
//  TranscriptCleaner.swift
//  Speakin
//
//  Apple's transcriber is close to verbatim: "um", "uh", "erm", "hmm" come through. This strips
//  them (English only) and repairs the punctuation and capitalization around the gap.
//

import Foundation

nonisolated enum TranscriptCleaner {
    /// Standalone disfluencies with any punctuation glued to them. Word boundaries exclude letters,
    /// digits, apostrophes and hyphens so "umbrella", "5mm" or "uh-huh" are left alone.
    private static let filler = try! NSRegularExpression(
        pattern: #"(?i)(?<![\p{L}\d'’-])(?:u+m+|u+h+|uhm+|erm+|hm+|mhm+)(?![\p{L}\d'’-])[,.…]*"#
    )
    private static let sentenceEnd: Set<Character> = [".", "!", "?", "…", "\n"]

    static func supports(_ locale: Locale) -> Bool {
        locale.language.languageCode?.identifier == "en"
    }

    static func removeFillerWords(from text: String, locale: Locale) -> String {
        guard supports(locale) else { return text }
        let ns = text as NSString
        let matches = filler.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }

        var result = text
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let matched = result[range]
            var head = String(result[..<range.lowerBound])
            var tail = Substring(result[range.upperBound...]).drop(while: { $0 == " " })
            while head.last == " " { head.removeLast() }

            // "I think, um, we" / "First line, um." — the comma that set the filler off goes too.
            if head.last == "," { head.removeLast() }

            // "First line, um." — a sentence mark glued to the filler still ends the sentence.
            if let mark = matched.first(where: { sentenceEnd.contains($0) }),
               !head.isEmpty, !sentenceEnd.contains(head.last!) {
                head.append(mark)
            }

            // The transcriber capitalizes sentence starts. A capitalized filler at a sentence start
            // means the next word now opens the sentence.
            let atSentenceStart = head.isEmpty || sentenceEnd.contains(head.last!)
            if atSentenceStart, matched.first?.isUppercase == true, let first = tail.first, first.isLowercase {
                tail = Substring(first.uppercased() + tail.dropFirst())
            }

            let needsSpace = !head.isEmpty && !tail.isEmpty
                && !(tail.first!.isNewline || tail.first!.isPunctuation)
            result = head + (needsSpace ? " " : "") + tail
        }

        result = result.replacingOccurrences(of: #" +([,.!?;:…])"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #",{2,}"#, with: ",", options: .regularExpression)
        result = result.replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
