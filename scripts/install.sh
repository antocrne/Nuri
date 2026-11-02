#!/bin/sh
# Builds Nuri in Release, replaces /Applications/Nuri.app and opens it.
set -e
cd "$(dirname "$0")/.."
xcodegen generate >/dev/null
# Outside ~/Documents: iCloud adds attributes that make code signing fail.
DERIVED="$HOME/Library/Developer/Xcode/DerivedData/Nuri-cli"
xcodebuild -project Nuri.xcodeproj -scheme Nuri -configuration Release -derivedDataPath "$DERIVED" build | tail -1
osascript -e 'tell application id "app.nuri.browser" to quit' 2>/dev/null || true
sleep 1
ditto "$DERIVED/Build/Products/Release/Nuri.app" /Applications/Nuri.app
open /Applications/Nuri.app
