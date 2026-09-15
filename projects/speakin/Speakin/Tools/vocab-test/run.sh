#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${TMPDIR:-/tmp}/speakin-vocab-test"
mkdir -p "$OUT"
swiftc -O -default-isolation MainActor -o "$OUT/vocab-test" Speakin/Vocabulary/Phonetics.swift Speakin/Vocabulary/VocabularyFixer.swift Speakin/Vocabulary/WordOracle.swift Speakin/Vocabulary/TranscriptDiff.swift Speakin/Vocabulary/VocabularyStore.swift Speakin/Log.swift Tools/vocab-test/main.swift -framework AppKit
"$OUT/vocab-test"
