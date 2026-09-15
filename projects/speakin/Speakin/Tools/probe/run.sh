#!/bin/zsh
# Builds and runs the speech probe against a spoken sentence generated with `say`.
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${TMPDIR:-/tmp}/speakin-probe"
mkdir -p "$OUT"
TEXT="${1:-Hello, this is a test of the Speakin dictation engine. It should transcribe every word, even when I keep talking for a while, and then paste it where my cursor is.}"
say -o "$OUT/sample.aiff" "$TEXT"
# Stereo 48 kHz version, like a typical USB microphone.
afconvert -f WAVE -d LEI16@48000 -c 2 "$OUT/sample.aiff" "$OUT/sample-48k-stereo.wav"
swiftc -O -parse-as-library \
  -default-isolation MainActor \
  -o "$OUT/probe" \
  Speakin/Audio/AudioFormatConverter.swift \
  Speakin/Audio/WAVWriter.swift \
  Speakin/Speech/SpeechEngine.swift \
  Tools/probe/main.swift \
  -framework Speech -framework AVFoundation
echo "== expected: $TEXT"
"$OUT/probe" "$OUT/sample-48k-stereo.wav" "${2:-en-US}"
