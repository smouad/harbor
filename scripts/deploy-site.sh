#!/bin/bash
# Publishes site/ as the landing page (GitHub Pages, from the gh-pages branch of smouad/harbor).
#
#   scripts/deploy-site.sh
#
# The page shows the latest GitHub Release: {{VERSION}}, {{DMG_URL}} and {{DMG_MB}} in site/index.html
# are filled from it, so scripts/release.sh runs this after publishing and the page follows every
# version. Run it by hand to publish an edit to the page itself. Needs the release to carry a
# Harbor-<version>.dmg asset (release.sh uploads one). The branch is rebuilt from scratch each time.
set -euo pipefail
cd "$(dirname "$0")/.."

repo=smouad/harbor
release=$(gh release view --repo "$repo" --json tagName,assets)
version=$(jq -r '.tagName | ltrimstr("v")' <<<"$release")
dmg=$(jq -c --arg n "Harbor-$version.dmg" '.assets[] | select(.name == $n)' <<<"$release")
[ -n "$dmg" ] || { echo "Release v$version has no Harbor-$version.dmg asset" >&2; exit 1; }
url=$(jq -r .url <<<"$dmg")
mb=$(jq -r '(.size / 1000000 | round)' <<<"$dmg")

out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
rsync -a --exclude downloads --exclude screenshots site/ "$out/"
touch "$out/.nojekyll"
sed -i '' -e "s|{{VERSION}}|$version|g" -e "s|{{DMG_URL}}|$url|g" -e "s|{{DMG_MB}}|$mb|g" "$out/index.html"
! grep -q '{{' "$out/index.html" || { echo "Unfilled placeholder in index.html" >&2; exit 1; }

git -C "$out" init -q -b gh-pages
git -C "$out" add -A
git -C "$out" -c user.name="$(git config user.name)" -c user.email="$(git config user.email)" \
    commit -q -m "Harbor $version landing page"
git -C "$out" push -q --force "https://github.com/$repo.git" gh-pages

gh api "repos/$repo/pages" >/dev/null 2>&1 \
    || gh api -X POST "repos/$repo/pages" -f 'source[branch]=gh-pages' -f 'source[path]=/' >/dev/null
echo "Landing page for $version: $(gh api "repos/$repo/pages" --jq .html_url)"
