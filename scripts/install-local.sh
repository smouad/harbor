#!/bin/bash
# Builds Release, signs it, and installs it as /Applications/Harbor.app, the one copy to run.
#
#   scripts/install-local.sh [--no-launch]
#
# The signing identity is the first "Apple Development" certificate in the keychain, or the one in
# $HARBOR_SIGN_IDENTITY. Unlike the ad-hoc signature earlier builds carried, it is the same on
# every build, so the Keychain (vault secrets, saved passwords) keeps recognising the app.
# Harbor-CI.entitlements is the reduced set that needs no provisioning profile.
set -euo pipefail
cd "$(dirname "$0")/.."

app=build-release/Build/Products/Release/Harbor.app
dest=/Applications/Harbor.app
identity=${HARBOR_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')}
[ -n "$identity" ] || { echo "No Apple Development signing identity found" >&2; exit 1; }

xcodebuild -scheme Harbor -configuration Release -arch arm64 -derivedDataPath build-release \
    ENABLE_CODE_COVERAGE=NO CLANG_COVERAGE_MAPPING=NO \
    CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -quiet

codesign --force --deep --sign "$identity" --entitlements "$PWD/Harbor/Harbor-CI.entitlements" "$app"
codesign --verify --deep --strict "$app"

# Two copies share one set of tabs and settings: quit whichever runs before replacing it.
osascript -e 'tell application id "com.mouad.harbor" to quit' 2>/dev/null || true
for _ in $(seq 1 100); do pgrep -f "Harbor.app/Contents/MacOS/Harbor( |$)" >/dev/null || break; sleep 0.2; done

rm -rf "$dest"
ditto "$app" "$dest"
echo "Installed $dest, signed as: $identity"
[ "${1:-}" = "--no-launch" ] || open "$dest"
