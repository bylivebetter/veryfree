#!/bin/zsh
# Builds a Release Speakin.app and installs it into /Applications, replacing any previous copy.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -project Speakin.xcodeproj -scheme Speakin -configuration Release -derivedDataPath build -quiet build
pkill -x Speakin 2>/dev/null || true
rm -rf /Applications/Speakin.app
ditto build/Build/Products/Release/Speakin.app /Applications/Speakin.app
open /Applications/Speakin.app
echo "Installed /Applications/Speakin.app"
