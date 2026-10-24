#!/bin/bash
# Packs Harbor.app into the installer disk image: the artwork and volume icon are in scripts/dmg/,
# settings.py is the window layout, and make-background.swift repaints the artwork's version line
# from the app's own version. dmgbuild writes the layout itself, so Finder never opens a window.
# It is installed into build-release/dmgenv on first use (needs network once).
#
#   scripts/make-dmg.sh <Harbor.app> <out.dmg>
set -euo pipefail
cd "$(dirname "$0")/.."

app=${1:-}
out=${2:-}
[ -d "$app" ] && [ -n "$out" ] || { echo "usage: scripts/make-dmg.sh <Harbor.app> <out.dmg>" >&2; exit 2; }
case "$out" in /*) ;; *) out="$PWD/$out" ;; esac
case "$app" in /*) ;; *) app="$PWD/$app" ;; esac

env=build-release/dmgenv
if [ ! -x "$env/bin/dmgbuild" ]; then
    python3 -m venv "$env"
    "$env/bin/pip" install -q "dmgbuild==1.6.5"
fi

version=$(defaults read "$app/Contents/Info" CFBundleShortVersionString)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
swiftc -O scripts/dmg/make-background.swift -o "$work/make-background"
"$work/make-background" scripts/dmg/background.tiff "$version" "$work/background.tiff"

mkdir -p "$(dirname "$out")"
rm -f "$out"
"$env/bin/dmgbuild" -s scripts/dmg/settings.py \
    -D app="$app" -D background="$work/background.tiff" -D icon="$PWD/scripts/dmg/VolumeIcon.icns" \
    Harbor "$out" >/dev/null
