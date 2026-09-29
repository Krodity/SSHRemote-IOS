#!/usr/bin/env bash
# Build, sign and install SSH Remote on a USB-connected, unlocked iPhone.
#   ./install.sh          build + install (same as `xtool dev`)
#   ./install.sh build    build only
#
# The Swift toolchain's own bin dir must come first on PATH: some Linux
# packages only link the main `swift` command into /usr/bin, and the build
# looks for helpers such as swift-autolink-extract next to whichever `swift`
# it found. Resolve the real toolchain dir from the `swift` on PATH.
set -euo pipefail
cd "$(dirname "$0")"
command -v xtool >/dev/null || { echo "xtool not found — see README.md → Building" >&2; exit 1; }
command -v swift >/dev/null || { echo "swift not found — see README.md → Building" >&2; exit 1; }
SWIFT_BIN="$(dirname "$(readlink -f "$(command -v swift)")")"
export PATH="$SWIFT_BIN:$PATH"
exec xtool dev "$@"
