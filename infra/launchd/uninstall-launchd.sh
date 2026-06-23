#!/usr/bin/env bash
# Stop and remove the Pinch LaunchAgents. Idempotent and non-destructive:
# it does not touch your .env, tunnel credentials, or logs.
set -euo pipefail

GUI_DOMAIN="gui/$(id -u)"
LA_DIR="$HOME/Library/LaunchAgents"

remove_one() {
  local label="$1"
  local plist="$LA_DIR/$label.plist"

  # bootout the running service (ignore if not loaded).
  if launchctl print "$GUI_DOMAIN/$label" >/dev/null 2>&1; then
    echo "Booting out $label"
    launchctl bootout "$GUI_DOMAIN/$label" 2>/dev/null || true
  else
    echo "$label not loaded; skipping bootout."
  fi

  if [[ -f "$plist" ]]; then
    echo "Removing $plist"
    rm -f "$plist"
  else
    echo "$plist not present; nothing to remove."
  fi
}

# Order matters: remove the watchdog FIRST, otherwise its next run would
# re-bootstrap the server/tunnel we're about to tear down.
remove_one "com.pinch.watchdog"
remove_one "com.pinch.tunnel"
remove_one "com.pinch.server"

echo
echo "Uninstalled. (Logs, .env, and tunnel credentials were left untouched.)"
