#!/bin/zsh
# Builds PS.app and packs it into build/PS-<version>.dmg: open it, drag PS onto Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-app.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
DMG="build/PS-$VERSION.dmg"

STAGE="$(mktemp -d)/PS"
mkdir -p "$STAGE"
ditto build/PS.app "$STAGE/PS.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -quiet -volname "PS $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
rm -rf "$(dirname "$STAGE")"
echo "Built $DMG ($(du -h "$DMG" | cut -f1))"
shasum -a 256 "$DMG"
