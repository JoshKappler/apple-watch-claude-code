#!/usr/bin/env bash
# Pinch desktop launcher — double-click to bring the wrist tether up.
#
# Idempotent + detached: makes sure the backend and a Cloudflare *quick* tunnel
# are running (starting only what's missing), then prints the wss URL + token to
# type into the watch. Everything runs under nohup, so you can close this window
# and walk away — it keeps serving while the Mac is logged in and awake.
#
# No account / sign-in: the quick tunnel is anonymous. Its trycloudflare URL is
# stable for as long as the tunnel process lives (until reboot); re-running after
# a reboot mints a new URL to enter on the watch once. Re-running while it's
# already up just reuses the live URL — no churn.
#
# Keep-awake is intentionally NOT handled here (you use your own `meth`).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
ENV_FILE="$REPO_ROOT/backend/.env"
TUNNEL_LOG="/tmp/pinch-tunnel.log"
BACKEND_LOG="/tmp/pinch-backend.log"
NODE_BIN="${NODE_BIN:-$(command -v node || echo /opt/homebrew/bin/node)}"

bold(){ printf '\033[1m%s\033[0m\n' "$1"; }
ok(){   printf '  \033[32m✓\033[0m %s\n' "$1"; }
info(){ printf '  • %s\n' "$1"; }
warn(){ printf '  \033[33m!\033[0m %s\n' "$1"; }
pause(){ read -r -p "Press Return to close this window… " _ || true; }
die(){ printf '\033[31merror:\033[0m %s\n' "$1" >&2; pause; exit 1; }

env_val(){ grep -E "^$1=" "$ENV_FILE" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"' || true; }
tunnel_url(){ grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$TUNNEL_LOG" 2>/dev/null | tail -n1 || true; }

[[ -f "$ENV_FILE" ]] || die "backend/.env not found — run ./setup.sh first."
PORT="$(env_val PORT)"; PORT="${PORT:-8787}"
TOKEN="$(env_val PINCH_TOKEN)"
[[ -n "${TOKEN//[[:space:]]/}" ]] || die "PINCH_TOKEN empty in backend/.env — run ./setup.sh."

clear 2>/dev/null || true
bold "Pinch — bringing the tether up"
echo

# --- 1. backend (reuse if already healthy) ----------------------------------
if curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
  ok "backend already up on :$PORT"
else
  [[ -f "$REPO_ROOT/backend/dist/index.js" ]] || die "backend not built — run: npm run build"
  ( cd "$REPO_ROOT/backend" && nohup "$NODE_BIN" dist/index.js >"$BACKEND_LOG" 2>&1 & )
  for _ in $(seq 1 50); do curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break; sleep 0.2; done
  curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 \
    && ok "backend started on :$PORT" \
    || die "backend failed to start — see $BACKEND_LOG"
fi

# --- 2. tunnel (reuse a live quick tunnel, else start a fresh one) -----------
command -v cloudflared >/dev/null 2>&1 || die "cloudflared not found — brew install cloudflared."
URL=""
if pgrep -f "cloudflared tunnel --url" >/dev/null 2>&1; then
  cand="$(tunnel_url)"
  if [[ -n "$cand" ]] && curl -fsS --max-time 8 "$cand/health" >/dev/null 2>&1; then
    URL="$cand"; ok "reusing the live tunnel (URL unchanged)"
  fi
fi
if [[ -z "$URL" ]]; then
  : > "$TUNNEL_LOG"
  nohup cloudflared tunnel --url "http://localhost:$PORT" --no-autoupdate >>"$TUNNEL_LOG" 2>&1 &
  for _ in $(seq 1 80); do URL="$(tunnel_url)"; [[ -n "$URL" ]] && break; sleep 0.5; done
  [[ -n "$URL" ]] || die "tunnel did not report a URL — see $TUNNEL_LOG"
  for _ in $(seq 1 20); do curl -fsS --max-time 8 "$URL/health" >/dev/null 2>&1 && break; sleep 0.5; done
  ok "tunnel up"
fi

# --- 3. tell you what to put on the watch -----------------------------------
WSS="wss://${URL#https://}/ws"
echo
bar="────────────────────────────────────────────────────────"
bold "On your watch → Settings, enter (only if they changed):"
printf '\033[36m%s\033[0m\n' "$bar"
printf '  URL    \033[1m%s\033[0m\n' "$WSS"
printf '  TOKEN  \033[1m%s\033[0m\n' "$TOKEN"
printf '\033[36m%s\033[0m\n' "$bar"
echo
ok "Tether is live. Close this window and walk away — it keeps serving"
info "while the Mac is logged in + awake (you've got 'meth' for sleep)."
info "Logs: $BACKEND_LOG · $TUNNEL_LOG"
echo
pause
