#!/bin/sh
# Builds a Debug copy of Nuri apart from the user's (its own identifier, folders and preferences)
# and runs its self-tests. Exits with an error if one fails: for continuous integration, and before
# a release.
#
# Usage: scripts/selftest.sh [sections] [report.md]
#   sections: as -NuriSelfTestOnly (split,hublot…); by default those that need neither the network
#   nor a real extension. "all" runs everything.
# NURI_SELFTEST_ADHOC=1 signs ad hoc (a machine without the team's certificate: GitHub's runners).
# NURI_SELFTEST_STRICT=1 also fails on tests that couldn't be verified (Nuri wasn't in front).
set -e
cd "$(dirname "$0")/.."
SECTIONS="${1:-session,onglets,porter,glisser,liens,split,hublot,espaces,dossiers,adresse,menus,fermer,son,veille,prive,calcul,commandes,focus,lecture,historique,signets,telechargements,pistage,permissions,langue,raccourcis,barre,mise-a-jour,reunion,partage-son,apercu,import,audit}"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/nuri-selftest.XXXXXX")
REPORT="${2:-$WORK/report.md}"
# Outside ~/Documents: iCloud adds attributes that make code signing fail.
SIGNING=""
[ -n "$NURI_SELFTEST_ADHOC" ] && SIGNING="CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="
command -v xcodegen >/dev/null && xcodegen generate >/dev/null
# shellcheck disable=SC2086
xcodebuild -project Nuri.xcodeproj -target Nuri -configuration Debug SYMROOT="$WORK/sym" OBJROOT="$WORK/obj" \
    PRODUCT_BUNDLE_IDENTIFIER=app.nuri.selftest $SIGNING build > "$WORK/build.log" 2>&1 || {
    grep -E "error:" "$WORK/build.log" | sort -u | head -40
    echo "Build failed: $WORK/build.log"
    exit 1
}
APP="$WORK/sym/Debug/Nuri.app"
mkdir -p "$WORK/home"
ONLY=""
[ "$SECTIONS" != "all" ] && ONLY="-NuriSelfTestOnly $SECTIONS"
# A home of its own: its Application Support, WebKit data and preferences aren't the user's.
# shellcheck disable=SC2086
CFFIXED_USER_HOME="$WORK/home" HOME="$WORK/home" "$APP/Contents/MacOS/Nuri" -NuriSelfTest features -NuriSelfTestOut "$REPORT" $ONLY \
    -onboardingCompleted YES -checkForUpdates NO > "$WORK/run.log" 2>&1 &
PID=$!
# A self-test stuck for good doesn't hold the build forever: its partial report says how far it went.
( sleep "${NURI_SELFTEST_TIMEOUT:-1800}"; kill "$PID" 2>/dev/null ) &
WATCH=$!
wait "$PID" || true
kill "$WATCH" 2>/dev/null || true
if [ ! -f "$REPORT" ]; then
    echo "No report: Nuri stopped before the end."
    [ -f "$REPORT.partial" ] && tail -20 "$REPORT.partial"
    tail -20 "$WORK/run.log"
    exit 1
fi
head -1 "$REPORT"
grep -E "❌|NON VÉRIFIÉ" "$REPORT" || true
echo "Report: $REPORT"
grep -q "❌" "$REPORT" && exit 1
[ -n "$NURI_SELFTEST_STRICT" ] && grep -q "NON VÉRIFIÉ" "$REPORT" && exit 1
exit 0
