//
//  Phonetics.swift
//  Speakin
//
//  "How does it sound" keys so that knockups ≈ Nocaps, Fannius ≈ Phaneus, Cuddo ≈ Kuddo.
//  A compact Metaphone variant plus a plain edit-distance similarity.
//

import Foundation

nonisolated enum Phonetics {
    /// Lowercase ASCII letters and digits only ("Épochler-2" → "epochler2").
    static func letters(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII }).lowercased()
    }

    private static let vowels: Set<Character> = ["a", "e", "i", "o", "u"]

    /// Consonant skeleton of the pronunciation. Words that sound alike get equal keys.
    static func key(_ word: String) -> String {
        var s = Array(letters(word).filter(\.isLetter))
        guard !s.isEmpty else { return "" }

        let head = String(s.prefix(2))
        if ["kn", "gn", "pn", "wr", "ae"].contains(head) {
            s.removeFirst()
        } else if head == "wh" {
            s.remove(at: 1)
        } else if s[0] == "x" {
            s[0] = "s"
        }

        var out = ""
        var i = 0
        func at(_ j: Int) -> Character? { j >= 0 && j < s.count ? s[j] : nil }
        while i < s.count {
            let c = s[i]
            let prev = at(i - 1)
            let next = at(i + 1)
            let next2 = at(i + 2)
            if let prev, prev == c, c != "c" { i += 1; continue }

            switch c {
            case "a", "e", "i", "o", "u":
                if i == 0 { out.append("a") }
            case "b":
                if !(prev == "m" && next == nil) { out.append("b") }
            case "c":
                if next == "h" {
                    // "ch" before a consonant is hard (Epochler, Christ); before a vowel it is "sh"-ish.
                    if let next2, !vowels.contains(next2) { out.append("k") } else { out.append("x") }
                    i += 1
                } else if let next, "eiy".contains(next) {
                    out.append("s")
                } else {
                    out.append("k")
                }
            case "d":
                if next == "g", let next2, "eiy".contains(next2) { out.append("j"); i += 2 } else { out.append("t") }
            case "g":
                if next == "h" {
                    if next2 == nil { out.append("f") } else if let next2, !vowels.contains(next2) { /* silent */ } else { out.append("k") }
                    i += 1
                } else if next == "n" && (next2 == nil || (next2 == "e" && at(i + 3) == "d")) {
                    // silent gn / gned
                } else if let next, "eiy".contains(next) {
                    out.append("j")
                } else {
                    out.append("k")
                }
            case "h":
                if let next, vowels.contains(next), !(prev.map { "csptg".contains($0) } ?? false) { out.append("h") }
            case "k":
                if prev != "c" { out.append("k") }
            case "p":
                if next == "h" { out.append("f"); i += 1 } else { out.append("p") }
            case "q":
                out.append("k")
            case "s":
                if next == "h" { out.append("x"); i += 1 }
                else if next == "i", let next2, "ao".contains(next2) { out.append("x") }
                else { out.append("s") }
            case "t":
                if next == "i", let next2, "ao".contains(next2) { out.append("x") }
                else if next == "h" { out.append("0"); i += 1 }
                else if !(next == "c" && next2 == "h") { out.append("t") }
            case "v":
                out.append("f")
            case "w", "y":
                if let next, vowels.contains(next) { out.append(c) }
            case "x":
                out.append("ks")
            case "z":
                out.append("s")
            default:
                out.append(c)
            }
            i += 1
        }
        return out
    }

    /// 1 - normalized Levenshtein distance over `letters`, in 0...1.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(letters(a)), y = Array(letters(b))
        if x.isEmpty || y.isEmpty { return x.isEmpty && y.isEmpty ? 1 : 0 }
        var prev = Array(0...y.count)
        var cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return 1 - Double(prev[y.count]) / Double(max(x.count, y.count))
    }
}
