#!/bin/bash
# Packs Harbor.app into a disk image with an Applications shortcut.
#
#   scripts/make-dmg.sh <Harbor.app> <out.dmg>
set -euo pipefail

app=${1:-}
out=${2:-}
[ -d "$app" ] && [ -n "$out" ] || { echo "usage: scripts/make-dmg.sh <Harbor.app> <out.dmg>" >&2; exit 2; }

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/Harbor.app"
ln -s /Applications "$stage/Applications"
mkdir -p "$(dirname "$out")"
rm -f "$out"
hdiutil create -volname Harbor -srcfolder "$stage" -format UDZO -fs HFS+ -quiet "$out"
