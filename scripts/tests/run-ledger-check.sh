#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
tmp=$(mktemp -d)
{ echo "import Foundation"; awk '/^@MainActor$/ {p=1} p {print} /^}$/ && p {exit}' Harbor/Managers/BrowserManager/BrowserManager+Import.swift; } > "$tmp/Ledger.swift"
swiftc -parse-as-library "$tmp/Ledger.swift" scripts/tests/ImportLedgerCheck.swift -o "$tmp/check"
"$tmp/check"
