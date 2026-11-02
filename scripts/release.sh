#!/bin/sh
# Publishes the current MARKETING_VERSION on GitHub, with the archive Nuri's updater looks for.
# Usage: scripts/release.sh notes.md
set -e
cd "$(dirname "$0")/.."
NOTES="${1:?Usage: scripts/release.sh notes.md}"
VERSION=$(sed -n 's/.*MARKETING_VERSION: "\(.*\)"/\1/p' project.yml)
REPOSITORY=$(sed -n 's/.*static let repository = "\(.*\)"/\1/p' Nuri/App/Updater.swift)
DERIVED="$HOME/Library/Developer/Xcode/DerivedData/Nuri-cli"
gh release view "v$VERSION" --repo "$REPOSITORY" >/dev/null 2>&1 && { echo "v$VERSION is already published"; exit 1; }
xcodegen generate >/dev/null
xcodebuild -project Nuri.xcodeproj -scheme Nuri -configuration Release -derivedDataPath "$DERIVED" build | tail -1
APP="$DERIVED/Build/Products/Release/Nuri.app"
codesign --verify --deep --strict "$APP"
mkdir -p build
ditto -c -k --keepParent "$APP" "build/Nuri-$VERSION.zip"
gh release create "v$VERSION" "build/Nuri-$VERSION.zip" --repo "$REPOSITORY" --title "Nuri $VERSION" --notes-file "$NOTES" --prerelease
