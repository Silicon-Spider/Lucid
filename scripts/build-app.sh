#!/bin/bash
# Builds dist/Lucid.app from the Swift package.
#
# LUCID_ENGINES=folder puts the engines in that folder inside the app, so that it needs
# nothing from Homebrew. scripts/package-mac.sh does that, for the download.
#
# The bundle is signed ad hoc. macOS ties the Accessibility grant to the exact build, so
# after rebuilding you need to switch Lucid off and on again in
# System Settings > Privacy & Security > Accessibility.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/LucidApp/Desk.swift)
[ -n "$VERSION" ] || { echo "Could not read Lucid's version from Sources/LucidApp/Desk.swift." >&2; exit 1; }
APP="dist/Lucid.app"

swift build -c release --product Lucid 2>&1 | grep -vE "XCTest|xcrun|^[[:space:]]*$" | tail -3
BINARY="$(swift build -c release --show-bin-path)/Lucid"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/Lucid"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Lucid</string>
    <key>CFBundleDisplayName</key>
    <string>Lucid</string>
    <key>CFBundleIdentifier</key>
    <string>com.siliconspider.lucid</string>
    <key>CFBundleExecutable</key>
    <string>Lucid</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Lucid listens while you hold the dictation key, and turns what you say into text on this Mac. Nothing leaves your Mac.</string>
</dict>
</plist>
PLIST

if [ -n "${LUCID_ENGINES:-}" ]; then
  cp -R "$LUCID_ENGINES" "$APP/Contents/Resources/engines"
  # Every program and library inside has to be signed before the app that holds them is.
  find "$APP/Contents/Resources/engines" -type f \( -perm -u+x -o -name '*.dylib' \) -exec codesign --force --sign - {} \;
fi
codesign --force --sign - "$APP"
echo "Built $APP (version $VERSION)"
