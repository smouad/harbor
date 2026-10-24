#!/bin/bash
# Builds Debug and runs it as an isolated copy (own bundle id, defaults, tabs, cookies and
# DevMCP token) beside the installed Harbor, with Browser Control on, launched in the background.
#
#   scripts/tests/agent-copy.sh [build|launch|quit|token|port|files]   (default: build + launch)
#
# HARBOR_AGENT_TAB_ACCESS (off, ask or always; default always) sets how far agents reach into the
# copy's own tabs, so agent_e2e.py can check each.
#
# The copy is com.mouad.harbor.agent on port 47911, so it never touches com.mouad.harbor.
set -euo pipefail
cd "$(dirname "$0")/../.."

bundle_id=${HARBOR_AGENT_BUNDLE:-com.mouad.harbor.agent}
port=${HARBOR_AGENT_PORT:-47911}
copy=/tmp/harbor-agent/Harbor.app
# The copy has no Downloads access; its tool files live here instead of ~/Downloads/Harbor MCP.
files=/tmp/harbor-agent-files
token_file="$HOME/Library/Application Support/$bundle_id/dev-mcp-token"

# HARBOR_AGENT_CONFIG=Release checks the optimized build, which has crashed where Debug did not.
config=${HARBOR_AGENT_CONFIG:-Debug}

build() {
    local derived=build
    [ "$config" = Release ] && derived=build-agent-release
    xcodebuild -scheme Harbor -configuration "$config" -arch arm64 -derivedDataPath "$derived" \
        ENABLE_CODE_COVERAGE=NO CLANG_COVERAGE_MAPPING=NO \
        CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -quiet
    rm -rf /tmp/harbor-agent && mkdir -p /tmp/harbor-agent
    ditto "$derived/Build/Products/$config/Harbor.app" "$copy"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" "$copy/Contents/Info.plist"
    codesign --force --deep --sign - --entitlements "$PWD/Harbor/Harbor-CI.entitlements" "$copy" 2>/dev/null
}

quit_copy() {
    osascript -e "tell application id \"$bundle_id\" to quit" 2>/dev/null || true
    for _ in $(seq 1 50); do pgrep -f "$copy/Contents/MacOS/Harbor" >/dev/null || return 0; sleep 0.1; done
    pkill -f "$copy/Contents/MacOS/Harbor" || true
}

launch() {
    quit_copy
    defaults write $bundle_id settings.didFinishOnboarding -bool true
    defaults write $bundle_id settings.developerMode -bool true
    defaults write $bundle_id settings.browserControlServer -bool true
    defaults write $bundle_id settings.agentTabAccess -string "${HARBOR_AGENT_TAB_ACCESS:-always}"
    mkdir -p "$files"
    # Debug builds install the test extension without its consent sheet (agent_e2e.py checks
    # that extensions run in agent tabs); a Release copy ignores the argument.
    open -g -n -a "$copy" --args -HarborDevMCPPort "$port" -HarborDevMCPFiles "$files" \
        -HarborTestExtension "$PWD/scripts/tests/agent-fixtures/extension"
    for _ in $(seq 1 100); do
        [ -s "$token_file" ] && curl -s -o /dev/null -m 1 "http://127.0.0.1:$port/mcp" && break
        sleep 0.2
    done
    # First launch work (filter lists, the blocker's rule lists) keeps the main thread busy for a
    # while; wait until three pings in a row answer quickly.
    local fast=0
    for _ in $(seq 1 240); do
        local took
        took=$(curl -s -o /dev/null -m 2 -w "%{time_total}" "http://127.0.0.1:$port/mcp" \
            -H "Authorization: Bearer $(cat "$token_file")" -H 'Content-Type: application/json' \
            -d '{"jsonrpc":"2.0","id":1,"method":"ping"}' || echo 9)
        if awk "BEGIN { exit !($took < 0.2) }"; then fast=$((fast + 1)); else fast=0; fi
        if [ $fast -ge 3 ]; then
            echo "Harbor agent copy up on port $port"
            return 0
        fi
        sleep 0.5
    done
    echo "Harbor agent copy did not settle" >&2
    return 1
}

case "${1:-all}" in
    build) build ;;
    launch) launch ;;
    quit) quit_copy ;;
    token) cat "$token_file" ;;
    port) echo "$port" ;;
    files) echo "$files" ;;
    all) build && launch ;;
    *) echo "usage: $0 [build|launch|quit|token|port|files]" >&2; exit 2 ;;
esac
