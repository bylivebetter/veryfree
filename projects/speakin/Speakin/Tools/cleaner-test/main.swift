// Checks TranscriptCleaner against known inputs. Run with Tools/cleaner-test/run.sh.
import Foundation

let en = Locale(identifier: "en_US")
let cases: [(String, String)] = [
    ("Um, I think we should go.", "I think we should go."),
    ("I think, um, we should go.", "I think we should go."),
    ("I think um we should go.", "I think we should go."),
    ("So uh, yeah. Um. That's it.", "So yeah. That's it."),
    ("Hmm, let me see... uh, the umbrella is 5mm wide, uh-huh.", "Let me see... the umbrella is 5mm wide, uh-huh."),
    ("Erm... I don't know. Uhh, maybe.", "I don't know. Maybe."),
    ("um", ""),
    ("No fillers here.", "No fillers here."),
    ("Ummm, what about the UM meeting?", "What about the meeting?"),
    ("First line, um.\nSecond line uh works.", "First line.\nSecond line works."),
]
var failures = 0
for (input, expected) in cases {
    let got = TranscriptCleaner.removeFillerWords(from: input, locale: en)
    if got != expected {
        failures += 1
        print("FAIL\n  in:  \(input.debugDescription)\n  exp: \(expected.debugDescription)\n  got: \(got.debugDescription)")
    }
}
let de = TranscriptCleaner.removeFillerWords(from: "Wir gehen um acht.", locale: Locale(identifier: "de_DE"))
if de != "Wir gehen um acht." { failures += 1; print("FAIL German untouched: \(de)") }
print(failures == 0 ? "all \(cases.count + 1) cases pass" : "\(failures) failure(s)")
exit(failures == 0 ? 0 : 1)
