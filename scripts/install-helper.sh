#!/bin/bash
# Installs Zephyr's fan helper as a system launch daemon. Run once; needs your admin password.
# Use this when the app is signed ad-hoc (no developer certificate), where SMAppService can't register it.
set -euo pipefail
APP="${1:-/Applications/Zephyr.app}"
HELPER_SRC="$APP/Contents/MacOS/ZephyrHelper"
LABEL="app.zephyr.Zephyr.helper"
DEST="/Library/PrivilegedHelperTools/$LABEL"
PLIST="/Library/LaunchDaemons/$LABEL.plist"

[ -x "$HELPER_SRC" ] || { echo "Can't find $HELPER_SRC — pass the path to Zephyr.app as the first argument."; exit 1; }

echo "Installing $LABEL for $APP (you'll be asked for your password)…"
sudo launchctl bootout system "$PLIST" 2>/dev/null || true
sudo mkdir -p /Library/PrivilegedHelperTools
sudo install -m 755 -o root -g wheel "$HELPER_SRC" "$DEST"
sudo tee "$PLIST" >/dev/null <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$LABEL</string>
	<key>ProgramArguments</key>
	<array><string>$DEST</string><string>--app</string><string>$APP/Contents/MacOS/Zephyr</string></array>
	<key>MachServices</key><dict><key>$LABEL</key><true/></dict>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key><true/>
</dict>
</plist>
PLISTEOF
sudo chown root:wheel "$PLIST"; sudo chmod 644 "$PLIST"
sudo launchctl bootstrap system "$PLIST"
echo "Done. Reopen Zephyr — fan control is now available."
