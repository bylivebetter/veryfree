//
//  WordOracle.swift
//  Speakin
//
//  "Is this an ordinary word?" — asked of macOS's spell checker in lowercase, which keeps the
//  user's own capitalized names (learned by typing them) from being mistaken for dictionary words.
//

import AppKit

@MainActor
final class WordOracle {
    static let shared = WordOracle()

    private let checker = NSSpellChecker.shared
    private var cache: [String: Bool] = [:]

    /// Spell-checker language for a transcription locale, falling back to English.
    func spellLanguage(for localeIdentifier: String?) -> String {
        guard let localeIdentifier else { return "en" }
        let available = checker.availableLanguages
        if available.contains(localeIdentifier) { return localeIdentifier }
        let underscored = localeIdentifier.replacingOccurrences(of: "-", with: "_")
        if available.contains(underscored) { return underscored }
        if let code = Locale(identifier: localeIdentifier).language.languageCode?.identifier {
            if available.contains(code) { return code }
            if let variant = available.first(where: { $0.hasPrefix(code + "_") }) { return variant }
        }
        return "en"
    }

    /// Ordinary word in the given language (default English).
    func isRealWord(_ word: String, language: String = "en") -> Bool {
        let key = language + "|" + word.lowercased()
        if let cached = cache[key] { return cached }
        let lower = word.lowercased()
        let range = checker.checkSpelling(of: lower, startingAt: 0, language: language, wrap: false,
                                          inSpellDocumentWithTag: 0, wordCount: nil)
        let real = range.location == NSNotFound
        cache[key] = real
        return real
    }

    /// A made-up word: app, project, person… worth learning.
    func isCoinedWord(_ word: String, language: String = "en") -> Bool {
        let letters = Phonetics.letters(word)
        guard letters.count >= 3, letters.contains(where: \.isLetter) else { return false }
        return !isRealWord(word, language: language)
    }

    /// Everyday words. A phrase made only of these ("to text", "live now") is left alone even when a
    /// vocabulary term is spelled exactly like it.
    nonisolated static let commonWords: Set<String> = Set("""
    a about above across after again against all almost alone along already also although always am among an and
    another any anyone anything anywhere are around as ask at away back bad be because been before behind being below
    best better between big both but by call came can cannot car case change check close come could country course
    cut day did different do does done down during each early end enough even ever every everyone everything eye face
    fact far feel few find first for form found free from full get give go going good got great group had hand hard
    has have he head hear help her here high him his home house how however i idea if important in inside interest
    into is it its just keep kind know large last late later least leave left less let life light like line little
    live long look lot made make man many may me mean might mind more most move much must my name need never new
    next no not nothing now number of off often old on once one only open or order other our out over own part people
    place play point put question quite rather read real really right room run said same saw say see seem seen set
    she should show side since small so some someone something sometimes soon start state still such sure take talk
    tell than that the their them then there these they thing think this those though thought three through time to
    today together too took top toward try turn two under until up upon us use used very want was watch water way we
    week well went were what when where whether which while who whole why will with within without word work world
    would write year yes yet you young your
    color colour text note notes list file files app apps page pages song music video photo photos image images
    speak speaking talk talking type typing write writing read reading mail email chat message messages send sent
    live now later soon fast slow quick hot cold warm cool dark light red blue green black white gray grey
    like this that these those
    """.split(whereSeparator: \.isWhitespace).map(String.init))

    nonisolated static func isCommonPhrase(_ words: [String]) -> Bool {
        !words.isEmpty && words.allSatisfy { commonWords.contains($0.lowercased()) }
    }
}
