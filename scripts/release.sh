#!/bin/bash
# Builds a universal, Developer-ID-signed Zephyr, packages a DMG, notarizes it and staples the ticket.
#
# One-time setup (you'll be asked for an app-specific password from your Apple Account):
#   xcrun notarytool store-credentials "zephyr-notary" --apple-id you@example.com --team-id YOURTEAMID
#
# Usage: TEAM_ID=YOURTEAMID SIGN_IDENTITY="Developer ID Application: Your Name (YOURTEAMID)" scripts/release.sh
#        add --no-notarize for a signed DMG only (Gatekeeper will warn).
set -euo pipefail
cd "$(dirname "$0")/.."

: "${TEAM_ID:?Set TEAM_ID to your Apple developer Team ID}"
: "${SIGN_IDENTITY:?Set SIGN_IDENTITY to your Developer ID Application certificate name}"
PROFILE="${NOTARY_PROFILE:-zephyr-notary}"
VERSION=$(grep -E '^\s+MARKETING_VERSION' project.yml | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
APP="build/Build/Products/Release/Zephyr.app"
DMG="dist/Zephyr-$VERSION.dmg"

command -v xcodegen >/dev/null && xcodegen generate >/dev/null
rm -rf build dist; mkdir -p dist
echo "▸ Building universal app…"
xcodebuild -project Zephyr.xcodeproj -scheme Zephyr -configuration Release -derivedDataPath build \
  -destination 'generic/platform=macOS' CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
  DEVELOPMENT_TEAM="$TEAM_ID" build | grep -E "error:|\*\* BUILD" || [ "${PIPESTATUS[0]}" -eq 0 ]
codesign --verify --deep --strict "$APP"

echo "▸ Creating DMG…"
STAGE=$(mktemp -d); ditto "$APP" "$STAGE/Zephyr.app"; ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Zephyr" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"

if [ "${1:-}" = "--no-notarize" ]; then echo "Done (not notarized): $DMG"; exit 0; fi
echo "▸ Notarizing…"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
echo "Done: $DMG"
