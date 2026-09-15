#!/bin/zsh
# Regenerates Speakin/Assets.xcassets/AppIcon.appiconset from Tools/icon/main.swift.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${TMPDIR:-/tmp}/speakin-icon"
mkdir -p "$OUT"
swiftc -O -default-isolation MainActor -o "$OUT/make-icon" Tools/icon/main.swift -framework AppKit
"$OUT/make-icon" Speakin/Assets.xcassets/AppIcon.appiconset
