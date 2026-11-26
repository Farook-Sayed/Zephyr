#!/bin/bash
# Usage: scripts/build.sh [adhoc|signed]
#   adhoc  (default) – no certificate needed; fine for you and for testers who run scripts/install-helper.sh
#   signed           – uses the Team you set in Xcode / DEVELOPMENT_TEAM (Apple Development or Developer ID)
set -euo pipefail
cd "$(dirname "$0")/.."
MODE="${1:-adhoc}"
command -v xcodegen >/dev/null && xcodegen generate >/dev/null
ARGS=(-project Zephyr.xcodeproj -scheme Zephyr -configuration Release -derivedDataPath build)
if [ "$MODE" = adhoc ]; then ARGS+=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=); fi
xcodebuild "${ARGS[@]}" build | grep -E "error:|warning: |BUILD" || [ "${PIPESTATUS[0]}" -eq 0 ]
echo "Built: build/Build/Products/Release/Zephyr.app"
