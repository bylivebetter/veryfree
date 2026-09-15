#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${TMPDIR:-/tmp}/speakin-cleaner-test"
mkdir -p "$OUT"
swiftc -O -default-isolation MainActor -o "$OUT/cleaner-test" Speakin/Speech/TranscriptCleaner.swift Tools/cleaner-test/main.swift
"$OUT/cleaner-test"
