#!/usr/bin/env bash
# Install the Pinch LaunchAgents (backend server + Cloudflare Tunnel) so they
# start at login and restart on crash. Idempotent: re-running re-installs.
#
# Usage:
#   infra/launchd/install-launchd.sh
#
# Override any of these via env before running:
#   NODE_BIN          path to node          (default: `command -v node`)
#   CLOUDFLARED_BIN   path to cloudflared   (default: `command -v cloudflared`)
#   BACKEND_DIR       backend workspace dir (default: <repo>/backend)
#   TUNNEL_CONFIG     cloudflared config    (default: $HOME/.cloudflared/config.yml)
#   LOG_DIR           log directory         (default: $HOME/Library/Logs/pinch)
set -euo pipefail

# --- locate things ----------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

NODE_BIN="${NODE_BIN:-$(command -v node || true)}"
CLOUDFLARED_BIN="${CLOUDFLARED_BIN:-$(command -v cloudflared || true)}"
BACKEND_DIR="${BACKEND_DIR:-$REPO_ROOT/backend}"
TUNNEL_CONFIG="${TUNNEL_CONFIG:-$HOME/.cloudflared/config.yml}"
LOG_DIR="${LOG_DIR:-$HOME/Library/Logs/pinch}"
LA_DIR="$HOME/Library/LaunchAgents"

# --- validate ---------------------------------------------------------------
fail=0
if [[ -z "$NODE_BIN" || ! -x "$NODE_BIN" ]]; then
  echo "error: node not found. Set NODE_BIN=/abs/path/to/node" >&2; fail=1
fi
if [[ -z "$CLOUDFLARED_BIN" || ! -x "$CLOUDFLARED_BIN" ]]; then
  echo "error: cloudflared not found. brew install cloudflared, or set CLOUDFLARED_BIN" >&2; fail=1
fi
if [[ ! -d "$BACKEND_DIR" ]]; then
  echo "error: backend dir not found: $BACKEND_DIR" >&2; fail=1
fi
if [[ ! -f "$BACKEND_DIR/dist/index.js" ]]; then
  echo "warning: $BACKEND_DIR/dist/index.js missing — build first:" >&2
  echo "         npm run build --workspace backend" >&2
  # not fatal; you may build after install and kickstart.
fi
if [[ ! -f "$TUNNEL_CONFIG" ]]; then
  echo "error: tunnel config not found: $TUNNEL_CONFIG" >&2
  echo "       See infra/cloudflared/README.md for the one-time setup." >&2; fail=1
fi
[[ "$fail" -eq 0 ]] || exit 1

mkdir -p "$LA_DIR" "$LOG_DIR"

GUI_DOMAIN="gui/$(id -u)"

# render <template> <dest> : substitute placeholders into a plist.
render() {
  local template="$1" dest="$2"
  # Use a delimiter unlikely to appear in paths; escape & for sed replacement.
  sed \
    -e "s|__NODE_BIN__|$(printf '%s' "$NODE_BIN" | sed 's/[&|]/\\&/g')|g" \
    -e "s|__CLOUDFLARED_BIN__|$(printf '%s' "$CLOUDFLARED_BIN" | sed 's/[&|]/\\&/g')|g" \
    -e "s|__BACKEND_DIR__|$(printf '%s' "$BACKEND_DIR" | sed 's/[&|]/\\&/g')|g" \
    -e "s|__TUNNEL_CONFIG__|$(printf '%s' "$TUNNEL_CONFIG" | sed 's/[&|]/\\&/g')|g" \
    -e "s|__LOG_DIR__|$(printf '%s' "$LOG_DIR" | sed 's/[&|]/\\&/g')|g" \
    "$template" > "$dest"
}

install_one() {
  local label="$1" template="$2"
  local dest="$LA_DIR/$label.plist"
  echo "Installing $label -> $dest"
  render "$template" "$dest"

  # bootout first (ignore failure if not loaded), then bootstrap + kickstart.
  launchctl bootout "$GUI_DOMAIN/$label" 2>/dev/null || true
  launchctl bootstrap "$GUI_DOMAIN" "$dest"
  launchctl kickstart -k "$GUI_DOMAIN/$label"
  echo "  loaded and kickstarted."
}

install_one "com.pinch.server" "$SCRIPT_DIR/com.pinch.server.plist"
install_one "com.pinch.tunnel" "$SCRIPT_DIR/com.pinch.tunnel.plist"

echo
echo "Done. Logs: $LOG_DIR/{server,tunnel}.{out,err}.log"
echo "Check status:  launchctl print $GUI_DOMAIN/com.pinch.server | head -n 20"
echo "Stop/remove:   infra/launchd/uninstall-launchd.sh"
