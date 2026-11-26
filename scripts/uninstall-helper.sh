#!/bin/bash
# Removes the fan helper and hands the fans back to macOS.
set -euo pipefail
LABEL="app.zephyr.Zephyr.helper"
sudo launchctl bootout system "/Library/LaunchDaemons/$LABEL.plist" 2>/dev/null || true
sudo rm -f "/Library/LaunchDaemons/$LABEL.plist" "/Library/PrivilegedHelperTools/$LABEL"
echo "Helper removed."
