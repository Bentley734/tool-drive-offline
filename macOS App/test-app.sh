#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/tool-drive-tests.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT
xcrun swiftc "$ROOT/macOS App/Updates.swift" "$ROOT/macOS App/tests/main.swift" -module-cache-path "$ROOT/macOS App/dist/compiler-cache" -o "$SCRATCH/checks"
"$SCRATCH/checks" "$ROOT" "$SCRATCH" "$@"
xcrun swiftc "$ROOT/macOS App/Updates.swift" "$ROOT/macOS App/LiveMedia.swift" \
  "$ROOT/macOS App/PlexService.swift" "$ROOT/macOS App/PlayerController.swift" \
  "$ROOT/macOS App/tests/test-live-media.swift" \
  -parse-as-library -module-cache-path "$ROOT/macOS App/dist/compiler-cache" \
  -framework AppKit -framework AVFoundation -framework MediaPlayer -framework Security \
  -o "$SCRATCH/live-media-checks"
"$SCRATCH/live-media-checks"
if [[ -f "$ROOT/macOS App/tests/test-library.swift" ]]; then
  xcrun swiftc "$ROOT/macOS App/Updates.swift" "$ROOT/macOS App/LiveMedia.swift" \
    "$ROOT/macOS App/LibraryController.swift" \
    "$ROOT/macOS App/tests/test-library.swift" -parse-as-library \
    -module-cache-path "$ROOT/macOS App/dist/compiler-cache" -framework AppKit -framework AudioToolbox \
    -o "$SCRATCH/library-checks"
  "$SCRATCH/library-checks"
fi
if [[ -f "$ROOT/macOS App/tests/test-plex.swift" ]]; then
  xcrun swiftc "$ROOT/macOS App/Updates.swift" "$ROOT/macOS App/LiveMedia.swift" \
    "$ROOT/macOS App/PlexService.swift" "$ROOT/macOS App/tests/test-plex.swift" -parse-as-library \
    -module-cache-path "$ROOT/macOS App/dist/compiler-cache" -framework AppKit -framework Security \
    -o "$SCRATCH/plex-checks"
  "$SCRATCH/plex-checks"
fi
python3 "$ROOT/macOS App/tests/test-helper.py" "$ROOT" "$SCRATCH"
python3 "$ROOT/macOS App/tests/test-themes.py"
python3 "$ROOT/verify_catalog.py"
if [[ "${TOOL_DRIVE_GUI_TEST:-0}" == "1" && -x "$ROOT/macOS App/dist/Tool Drive Offline.app/Contents/MacOS/ToolDriveOffline" ]]; then
  mkdir -p "$SCRATCH/gui-data"
  TOOL_DRIVE_DATA_DIR="$SCRATCH/gui-data" \
    "$ROOT/macOS App/dist/Tool Drive Offline.app/Contents/MacOS/ToolDriveOffline" --self-test
fi
