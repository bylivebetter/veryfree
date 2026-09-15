// Checks Phonetics and VocabularyFixer against real misrecognitions seen from the speech model.
import Foundation

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if !ok { failures += 1; print("FAIL \(label) \(detail())") }
}

// Phonetic keys: each pair must collide.
for (heard, name) in [("knockups", "Nocaps"), ("Nomo", "Knomo"), ("Cuddo", "Kuddo"), ("Fannius", "Phaneus"),
                      ("Epicler", "Epochler"), ("knock ups", "Nocaps"), ("Latoof", "Lattouf"), ("Whats App", "WhatsApp")] {
    let a = Phonetics.key(heard), b = Phonetics.key(name)
    check("key \(heard)~\(name)", a == b, "\(a) vs \(b)")
}
// Distinct words must not collide.
for (x, y) in [("Nocaps", "Knomo"), ("Kuddo", "cutkit"), ("baton", "button"), ("Speakin", "Spotify")] {
    check("distinct \(x)/\(y)", Phonetics.key(x) != Phonetics.key(y) || Phonetics.similarity(x, y) < 0.7, Phonetics.key(x))
}
check("similarity speaking/speakin", Phonetics.similarity("speaking", "Speakin") >= 0.8, "\(Phonetics.similarity("speaking", "Speakin"))")
check("similarity nocaps/knockups", Phonetics.similarity("knockups", "Nocaps") >= 0.5)

print(failures == 0 ? "phonetics: all pass" : "phonetics: \(failures) failure(s)")

// Fixer: what the speech model actually produced for the spoken names.
import AppKit
let checker = NSSpellChecker.shared
let isReal: @Sendable (String) -> Bool = { word in
    MainActor.assumeIsolated { checker.checkSpelling(of: word, startingAt: 0, language: "en", wrap: false, inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound }
}
let terms = ["Nocaps", "Speakin", "Knomo", "Kuddo", "Phaneus", "Epochler", "Lattouf"].map(VocabularyTerm.init)
let common: @Sendable ([String]) -> Bool = { WordOracle.isCommonPhrase($0) }
let fixer = VocabularyFixer(terms: terms + [VocabularyTerm("Totext"), VocabularyTerm("Livenow")], corrections: ["knockups": "Nocaps"], isRealWord: isReal, isCommonPhrase: common)
let fixerNoLLM = VocabularyFixer(terms: terms, corrections: [:], isRealWord: isReal, isCommonPhrase: common)

let r1 = fixer.fix("I am working on knockups and speaking today. Nomo and Cuddo are next, then Fannius and Epicler.")
// "Nomo" is a dictionary proper noun, so it can only be fixed by a learned correction.
check("sentence 1", r1.text == "I am working on Nocaps and speaking today. Nomo and Kuddo are next, then Phaneus and Epochler.", r1.text)
check("sentence 1 candidates", r1.candidates.map(\.heard) == ["speaking", "Nomo"], "\(r1.candidates)")

let r2 = fixer.fix("Yesterday I shipped a new build of knock ups and the speaking overlay finally works no more needs a login screen.")
check("sentence 2 learned split form", r2.text == "Yesterday I shipped a new build of Nocaps and the speaking overlay finally works no more needs a login screen.", r2.text)
check("sentence 2 candidates", Set(r2.candidates.map(\.heard)) == ["speaking"], "\(r2.candidates)")

let r6 = fixer.fix("I want to text him, we are live now, and the no caps launch is close.")
check("common phrases untouched", r6.text == "I want to text him, we are live now, and the Nocaps launch is close.", r6.text)
check("common phrase candidates", Set(r6.candidates.map(\.heard)) == ["to text", "live now"], "\(r6.candidates)")

let d1 = TranscriptDiff.changes(from: "I am working on knockups and speaking today. Nomo is next.", to: "I am working on Nocaps and Speakin today. Knomo is next.")
check("diff", d1 == [.init(heard: "knockups", corrected: "Nocaps"), .init(heard: "speaking", corrected: "Speakin"), .init(heard: "Nomo", corrected: "Knomo")], "\(d1)")
let d2 = TranscriptDiff.changes(from: "the no caps app", to: "the Nocaps app")
check("diff phrase", d2 == [.init(heard: "no caps", corrected: "Nocaps")], "\(d2)")
let d3 = TranscriptDiff.changes(from: "same text here", to: "same text here")
check("diff none", d3.isEmpty, "\(d3)")

let r3 = fixer.fix("The no caps app, nocaps, and NOCAPS.")
check("exact phrase + casing", r3.text == "The Nocaps app, Nocaps, and Nocaps.", r3.text)
let r3b = fixerNoLLM.fix("The no caps app needs work.")
check("exact phrase without corrections", r3b.text == "The Nocaps app needs work.", r3b.text)

let r4 = fixer.fix("Elias Latoof wrote it. The button and the baton stay. Speaking of which, nothing else changes.")
check("names + untouched words", r4.text == "Elias Lattouf wrote it. The button and the baton stay. Speaking of which, nothing else changes.", r4.text)
check("real-word candidate only", r4.candidates.map(\.heard) == ["Speaking"], "\(r4.candidates)")

let r5 = fixer.fix("Nothing here matches at all, honestly.")
check("no-op", r5.text == "Nothing here matches at all, honestly." && r5.candidates.isEmpty, r5.text)

print(failures == 0 ? "fixer: all pass" : "fixer: \(failures) failure(s)")

// Store: learn from an edit, persist, reload, and fix with what was learned.
MainActor.assumeIsolated {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("speakin-vocab-test-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let store = VocabularyStore(directory: dir)
    store.load()
    let learned = store.learn(from: TranscriptDiff.changes(from: "Elias Latauf will review the Yom build with speaking.", to: "Elias Lattouf will review the Youlmk build with Speakin."))
    let learnedCount = learned.count
    check("learned 3", learnedCount == 3, "\(learnedCount)")
    let reloaded = VocabularyStore(directory: dir)
    reloaded.load()
    let corrections = reloaded.corrections
    let terms = Set(reloaded.terms.map(\.text))
    check("persisted corrections", corrections == ["latauf": "Lattouf", "yom": "Youlmk", "speaking": "Speakin"], "\(corrections)")
    check("persisted learned terms", terms == ["Lattouf", "Youlmk", "Speakin"], "\(terms)")
    let fixer2 = VocabularyFixer(terms: reloaded.terms, corrections: reloaded.corrections, isRealWord: isReal, isCommonPhrase: common)
    let fixed = fixer2.fix("Elias Latauf and the Yom build.").text
    check("learned fix applies", fixed == "Elias Lattouf and the Youlmk build.", fixed)
    reloaded.addManual("Knomo")
    reloaded.remove(reloaded.entries.first { $0.text == "Youlmk" }!)
    let again = VocabularyStore(directory: dir); again.load()
    let final = Set(again.terms.map(\.text))
    check("manual + removal persisted", final == ["Lattouf", "Speakin", "Knomo"], "\(final)")
    try? FileManager.default.removeItem(at: dir)
}

print(failures == 0 ? "store: all pass" : "store: \(failures) failure(s)")
exit(failures == 0 ? 0 : 1)
