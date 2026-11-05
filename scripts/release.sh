#!/bin/sh
# Publishes the current MARKETING_VERSION on GitHub, with the archive Nuri's updater looks for.
# The app is signed with a Developer ID certificate and notarized by Apple, so that it opens on any
# Mac (Gatekeeper refuses an app signed "Apple Development" downloaded from the Internet).
#
# Usage: scripts/release.sh notes.md
#
# Once, beforehand:
#   - a "Developer ID Application" certificate of team Y35975BXD4 in the keychain (Xcode → Settings →
#     Accounts → Manage Certificates → +, or developer.apple.com);
#   - the notary's password kept in the keychain under a profile name:
#       xcrun notarytool store-credentials nuri-notary --apple-id <id> --team-id Y35975BXD4
#     (an app-specific password from appleid.apple.com). NURI_NOTARY_PROFILE names another profile.
# NURI_RELEASE_DRY_RUN=1 signs, notarizes and checks without publishing.
set -e
cd "$(dirname "$0")/.."
NOTES="${1:?Usage: scripts/release.sh notes.md}"
[ -f "$NOTES" ] || { echo "No notes file: $NOTES"; exit 1; }
VERSION=$(sed -n 's/.*MARKETING_VERSION: "\(.*\)"/\1/p' project.yml)
TEAM=$(sed -n 's/.*DEVELOPMENT_TEAM: \(.*\)/\1/p' project.yml | head -1)
REPOSITORY=$(sed -n 's/.*static let repository = "\(.*\)"/\1/p' Nuri/App/Updater.swift)
PROFILE="${NURI_NOTARY_PROFILE:-nuri-notary}"
# Outside ~/Documents: iCloud adds attributes that make code signing fail.
DERIVED="$HOME/Library/Developer/Xcode/DerivedData/Nuri-cli"

# Everything that can stop the release is checked before building.
IDENTITY=$(security find-identity -v -p codesigning | sed -n "s/.*\"\(Developer ID Application: .*($TEAM)\)\"/\1/p" | head -1)
if [ -z "$IDENTITY" ]; then
    echo "No \"Developer ID Application\" certificate of team $TEAM in the keychain."
    echo "Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application."
    exit 1
fi
if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "No notary credentials under the profile \"$PROFILE\":"
    echo "  xcrun notarytool store-credentials $PROFILE --apple-id <id> --team-id $TEAM"
    exit 1
fi
if [ -z "$NURI_RELEASE_DRY_RUN" ] && gh release view "v$VERSION" --repo "$REPOSITORY" >/dev/null 2>&1; then
    echo "v$VERSION is already published"
    exit 1
fi

echo "Building Nuri $VERSION, signed by $IDENTITY"
xcodegen generate >/dev/null
# --timestamp: notarization refuses a signature without Apple's secure timestamp.
xcodebuild -project Nuri.xcodeproj -scheme Nuri -configuration Release -derivedDataPath "$DERIVED" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM" PROVISIONING_PROFILE_SPECIFIER="" \
    ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS="--timestamp" build | tail -1
APP="$DERIVED/Build/Products/Release/Nuri.app"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dvv "$APP" 2>&1 | grep -q "Authority=Developer ID Application" || { echo "Not signed with Developer ID"; exit 1; }
codesign -dvv "$APP" 2>&1 | grep -q "Timestamp=" || { echo "Signature without a secure timestamp"; exit 1; }

mkdir -p build
ARCHIVE="build/Nuri-$VERSION.zip"
rm -f "$ARCHIVE"
ditto -c -k --keepParent "$APP" "$ARCHIVE"
echo "Sending to Apple's notary service (a few minutes)"
SUBMISSION=$(xcrun notarytool submit "$ARCHIVE" --keychain-profile "$PROFILE" --wait --output-format plist)
STATUS=$(echo "$SUBMISSION" | plutil -extract status raw -o - - 2>/dev/null || echo unknown)
if [ "$STATUS" != "Accepted" ]; then
    echo "Notarization: $STATUS"
    ID=$(echo "$SUBMISSION" | plutil -extract id raw -o - - 2>/dev/null || true)
    [ -n "$ID" ] && xcrun notarytool log "$ID" --keychain-profile "$PROFILE"
    exit 1
fi
# The ticket goes in the app itself: it opens without asking Apple, offline too. The archive is
# made again with it.
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
rm -f "$ARCHIVE"
ditto -c -k --keepParent "$APP" "$ARCHIVE"
# What Gatekeeper will say on another Mac.
spctl --assess --type execute --verbose=2 "$APP"

if [ -n "$NURI_RELEASE_DRY_RUN" ]; then
    echo "Dry run: $ARCHIVE is signed and notarized, nothing published"
    exit 0
fi
gh release create "v$VERSION" "$ARCHIVE" --repo "$REPOSITORY" --title "Nuri $VERSION" --notes-file "$NOTES" --prerelease
