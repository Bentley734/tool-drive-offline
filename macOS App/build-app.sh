#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/macOS App/dist"
APP="$DIST/Tool Drive Offline.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$DIST/compiler-cache"
SOURCES=(
  "$ROOT/macOS App/main.swift"
  "$ROOT/macOS App/AppIconController.swift"
  "$ROOT/macOS App/CatalogThemePreferences.swift"
  "$ROOT/macOS App/CatalogAppearance.swift"
  "$ROOT/macOS App/GlassWallpaperPreferences.swift"
  "$ROOT/macOS App/LiquidGlassToolbar.swift"
  "$ROOT/macOS App/Updates.swift"
  "$ROOT/macOS App/UpdateController.swift"
  "$ROOT/macOS App/LiveMedia.swift"
  "$ROOT/macOS App/PlayerController.swift"
  "$ROOT/macOS App/AudioAnalysis.swift"
  "$ROOT/macOS App/PlaybackEqualizer.swift"
  "$ROOT/macOS App/LibraryController.swift"
  "$ROOT/macOS App/DownloadBrowser.swift"
  "$ROOT/macOS App/PlexService.swift"
)
for ARCH in arm64 x86_64; do
  xcrun swiftc "${SOURCES[@]}" -O -target "$ARCH-apple-macosx11.0" -module-cache-path "$DIST/compiler-cache" \
    -framework AppKit -framework WebKit -framework AVFoundation -framework MediaPlayer \
    -framework AudioToolbox -framework Security -o "$DIST/tool-drive-$ARCH"
done
lipo -create "$DIST/tool-drive-arm64" "$DIST/tool-drive-x86_64" -output "$APP/Contents/MacOS/ToolDriveOffline"
python3 "$ROOT/macOS App/prepare-resources.py" "$ROOT" "$APP/Contents/Resources"
xcrun actool "$ROOT/macOS App/Themes/ToolDriveIcon.icon" \
  --compile "$APP/Contents/Resources" --platform macosx --target-device mac \
  --minimum-deployment-target 11.0 --app-icon ToolDriveIcon \
  --output-partial-info-plist "$DIST/icon-info.plist" --output-format human-readable-text --warnings --notices
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Tool Drive Offline</string>
<key>CFBundleDisplayName</key><string>Tool Drive Offline</string>
<key>CFBundleIdentifier</key><string>net.bentley734.tooldriveoffline</string>
<key>CFBundleExecutable</key><string>ToolDriveOffline</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>11.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
<key>NSLocalNetworkUsageDescription</key><string>Tool Drive Offline can connect directly to a Plex Media Server on your local network when you choose Plex playback.</string>
<key>NSHumanReadableCopyright</key><string>Independent live archive companion. See NOTICE.md for attribution.</string>
</dict></plist>
PLIST
python3 - "$ROOT/macOS App/VERSION" "$APP/Contents/Info.plist" "$DIST/icon-info.plist" <<'PYTHON'
import plistlib, re, sys
from pathlib import Path
version = Path(sys.argv[1]).read_text().strip()
assert re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version), 'Expected MAJOR.MINOR.PATCH'
p = Path(sys.argv[2])
info = plistlib.loads(p.read_bytes())
icon_info = plistlib.loads(Path(sys.argv[3]).read_bytes())
assert icon_info.get('CFBundleIconName') == 'ToolDriveIcon' and icon_info.get('CFBundleIconFile') == 'ToolDriveIcon', 'Missing compiled app icon'
info.update(icon_info)
info['CFBundleShortVersionString'] = version
info['CFBundleVersion'] = version
p.write_bytes(plistlib.dumps(info))
PYTHON
xcrun swiftc "$ROOT/macOS App/make-icon.swift" -module-cache-path "$DIST/compiler-cache" -o "$DIST/make-icon"
"$DIST/make-icon" "$ROOT/macOS App/Themes" "$DIST"
for style in AppIcon AppIcon2006; do
  python3 "$ROOT/macOS App/pack-icon.py" "$DIST/$style.iconset" "$APP/Contents/Resources/$style.icns"
done
rm -f "$APP/Contents/Resources/AppIconMulticolor.icns"
codesign --force --deep --sign "${MAC_SIGN_IDENTITY:--}" --options runtime "$APP"
plutil -lint "$APP/Contents/Info.plist"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/Tool.Drive.Offline.macOS.zip"
printf 'Built %s\n' "$APP"
