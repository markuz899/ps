#!/bin/zsh
# Builds a universal (arm64 + x86_64) release PS.app into ./build.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/PS"

APP=build/PS.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PS"
strip -x "$APP/Contents/MacOS/PS"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/en.lproj Resources/it.lproj "$APP/Contents/Resources/"
cp -R Sources/PSCore/Resources/Themes "$APP/Contents/Resources/Themes"

# The icon is drawn in code (Sources/PS/App/AppIcon.swift).
ICONSET="$(mktemp -d)/AppIcon.iconset"
"$APP/Contents/MacOS/PS" --export-iconset "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP"
echo "Built $APP ($(du -sh "$APP" | cut -f1))"
lipo -info "$APP/Contents/MacOS/PS"
