#!/bin/bash
# Builds Release from the working tree and installs it as /Applications/Harbor Dev.app, a second app
# beside the real Harbor for trying work that is not released yet.
#
#   scripts/install-dev.sh [--no-launch]
#
# It has its own bundle id (com.mouad.harbor.dev), so its tabs, logins, settings and keychain items
# are separate from Harbor's, and its update checks are off, so a release never replaces it.
# Signed like scripts/install-local.sh. Run it again to put newer work in.
set -euo pipefail
cd "$(dirname "$0")/.."

bundle_id=com.mouad.harbor.dev
app=build-dev/Build/Products/Release/Harbor.app
dest="/Applications/Harbor Dev.app"
identity=${HARBOR_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')}
[ -n "$identity" ] || { echo "No Apple Development signing identity found" >&2; exit 1; }

xcodebuild -scheme Harbor -configuration Release -arch arm64 -derivedDataPath build-dev \
    PRODUCT_BUNDLE_IDENTIFIER="$bundle_id" ENABLE_CODE_COVERAGE=NO CLANG_COVERAGE_MAPPING=NO \
    CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -quiet

plist="$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName 'Harbor Dev'" "$plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string 'Harbor Dev'" "$plist"
/usr/libexec/PlistBuddy -c "Set :SUEnableAutomaticChecks false" "$plist"
/usr/libexec/PlistBuddy -c "Delete :SUFeedURL" "$plist" 2>/dev/null || true

codesign --force --deep --sign "$identity" --entitlements "$PWD/Harbor/Harbor-CI.entitlements" "$app"
codesign --verify --deep --strict "$app"

osascript -e "tell application id \"$bundle_id\" to quit" 2>/dev/null || true
for _ in $(seq 1 100); do pgrep -f "Harbor Dev.app/Contents/MacOS/Harbor" >/dev/null || break; sleep 0.2; done

rm -rf "$dest"
ditto "$app" "$dest"
echo "Installed $dest ($bundle_id), signed as: $identity"
[ "${1:-}" = "--no-launch" ] || open "$dest"
