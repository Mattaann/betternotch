#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/betternotch-checks.XXXXXX")
trap 'rm -rf "$CHECK_DIR"' EXIT
python3 - "$CHECK_DIR/Views.swift" <<'PY'
from pathlib import Path
import sys
root = Path('BetterNotch')
source = (root / 'BetterNotchApp.swift').read_text()
source = source[:source.index('@main')] + source[source.index('struct NotchActivationZone'):]
delegate = (root / 'AppDelegate.swift').read_text()
source += '\n' + (root / 'Modules.swift').read_text()
source += '\nimport QuartzCore\n' + delegate[delegate.index('final class PanelSurface'):delegate.index('final class AppDelegate')]
Path(sys.argv[1]).write_text(source)
PY
xcrun swiftc -target "$(uname -m)-apple-macos13.0" -module-cache-path "$CHECK_DIR/ModuleCache" "$CHECK_DIR/Views.swift" Tests/CoreChecks.swift -o "$CHECK_DIR/CoreChecks"
"$CHECK_DIR/CoreChecks"
if command -v node >/dev/null 2>&1; then
    node Tests/browser-media.cjs
else
    printf '%s\n' 'JavaScript checks skipped: install Node.js and run node Tests/browser-media.cjs.'
fi
