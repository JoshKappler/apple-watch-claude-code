#!/usr/bin/env bash
# Start the named Cloudflare Tunnel "pinch" in the foreground.
# For unattended/always-on operation, use infra/launchd/ instead.
set -euo pipefail

# Allow overriding the config path; default to the standard cloudflared location.
CONFIG_PATH="${PINCH_TUNNEL_CONFIG:-$HOME/.cloudflared/config.yml}"
TUNNEL_NAME="${PINCH_TUNNEL_NAME:-pinch}"

if ! command -v cloudflared >/dev/null 2>&1; then
  echo "error: cloudflared not found. Install it with: brew install cloudflared" >&2
  exit 1
fi

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "error: tunnel config not found at: $CONFIG_PATH" >&2
  echo "       Copy infra/cloudflared/config.example.yml there and fill it in." >&2
  echo "       See infra/cloudflared/README.md for the one-time setup." >&2
  exit 1
fi

echo "Starting Cloudflare Tunnel '$TUNNEL_NAME' with config: $CONFIG_PATH"
exec cloudflared tunnel --config "$CONFIG_PATH" run "$TUNNEL_NAME"
