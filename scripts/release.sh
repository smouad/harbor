#!/bin/bash
# Builds Release, signs it, packages it for Sparkle and publishes it as a GitHub Release.
#
#   scripts/release.sh <version> [--notes <file>] [--dry-run]
#
# Harbor checks https://github.com/smouad/harbor/releases/latest/download/appcast.xml (SUFeedURL in
# Harbor/Info.plist), so publishing a release is what makes the sidebar offer the update. The build
# number is a timestamp, which only grows, because Sparkle orders updates by it. The version is what
# people see. --dry-run does everything but the upload and leaves the files in build-release/dist.
#
# Updates are signed with the EdDSA key that generate_keys put in the login keychain; the matching
# public key is SUPublicEDKey in Info.plist. Back the private key up with `generate_keys -x <file>`:
# without it no installed copy accepts another update. The app itself is signed with the first Apple
# Development certificate (or $HARBOR_SIGN_IDENTITY), like scripts/install-local.sh. That is enough
# for updating your own Mac; other Macs need a Developer ID certificate and notarization.
set -euo pipefail
cd "$(dirname "$0")/.."

usage() { echo "usage: scripts/release.sh <version> [--notes <file>] [--dry-run]" >&2; exit 2; }

version=${1:-}
[ -n "$version" ] || usage
shift
notes=""
dry_run=0
while [ $# -gt 0 ]; do
    case "$1" in
        --notes) notes=${2:-}; [ -f "$notes" ] || usage; shift 2 ;;
        --dry-run) dry_run=1; shift ;;
        *) usage ;;
    esac
done
[[ "$version" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || { echo "Version must look like 1.2 or 1.2.3" >&2; exit 2; }

repo=smouad/harbor
tag="v$version"
build=$(date +%Y%m%d%H%M)
app=build-release/Build/Products/Release/Harbor.app
dist=build-release/dist
sparkle=build-release/SourcePackages/artifacts/sparkle/Sparkle/bin
identity=${HARBOR_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')}
[ -n "$identity" ] || { echo "No Apple Development signing identity found" >&2; exit 1; }

if [ "$dry_run" = 0 ]; then
    gh auth status >/dev/null 2>&1 || { echo "gh is not signed in" >&2; exit 1; }
    [ "$(gh repo view "$repo" --json visibility --jq .visibility)" = PUBLIC ] \
        || { echo "$repo must be public for Sparkle to download from it" >&2; exit 1; }
    if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
        echo "Release $tag already exists" >&2; exit 1
    fi
fi

xcodebuild -scheme Harbor -configuration Release -arch arm64 -derivedDataPath build-release \
    MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build" \
    ENABLE_CODE_COVERAGE=NO CLANG_COVERAGE_MAPPING=NO \
    CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -quiet

[ -x "$sparkle/generate_appcast" ] || { echo "Sparkle tools missing: $sparkle" >&2; exit 1; }

codesign --force --deep --sign "$identity" --entitlements "$PWD/Harbor/Harbor-CI.entitlements" "$app"
codesign --verify --deep --strict "$app"

shipped=$(defaults read "$PWD/$app/Contents/Info" CFBundleShortVersionString)
[ "$shipped" = "$version" ] || { echo "Built $shipped, not $version" >&2; exit 1; }

# generate_appcast reads every archive in the folder, so start from an empty one.
rm -rf "$dist"
mkdir -p "$dist"
zip="Harbor-$version.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$dist/$zip"
[ -z "$notes" ] || cp "$notes" "$dist/Harbor-$version.md"
"$sparkle/generate_appcast" "$dist" \
    --download-url-prefix "https://github.com/$repo/releases/download/$tag/" \
    -o "$dist/appcast.xml"
grep -q "sparkle:edSignature" "$dist/appcast.xml" || { echo "appcast.xml has no signature" >&2; exit 1; }

if [ "$dry_run" = 1 ]; then
    echo "Dry run: $tag (build $build) is in $dist, nothing uploaded"
    exit 0
fi

[ -z "$(git status --porcelain --untracked-files=no)" ] || echo "Warning: uncommitted changes are in this build; the tag marks HEAD without them" >&2
git tag -a "$tag" -m "Harbor $version"
git push origin "$tag"
notes_flag=(--generate-notes)
[ -z "$notes" ] || notes_flag=(--notes-file "$notes")
gh release create "$tag" "$dist/$zip" "$dist/appcast.xml" --repo "$repo" --verify-tag \
    --title "Harbor $version" "${notes_flag[@]}"
echo "Published https://github.com/$repo/releases/tag/$tag"
