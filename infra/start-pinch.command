#!/usr/bin/env bash
# Pinch desktop launcher — double-click to bring the wrist tether up.
#
# Idempotent + detached: makes sure the backend and a STABLE ngrok tunnel are
# running (starting only what's missing), then prints the wss URL + token. The
# ngrok static domain (PINCH_NGROK_DOMAIN in backend/.env) NEVER changes, so the
# URL baked into the watch keeps working across restarts — no reflash to swap it.
#
# Everything runs under nohup, so you can close this window and walk away; it
# keeps serving while the Mac is logged in and awake.
#
# One-time ngrok auth (free): the agent must be authenticated once with
#   ngrok config add-authtoken <token>
# and PINCH_NGROK_DOMAIN must hold your reserved free static domain. Keep-awake is
# intentionally NOT handled here (you use your own `meth`).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
ENV_FILE="$REPO_ROOT/backend/.env"
NGROK_LOG="/tmp/pinch-ngrok.log"
BACKEND_LOG="/tmp/pinch-backend.log"
NODE_BIN="${NODE_BIN:-$(command -v node || echo /opt/homebrew/bin/node)}"

bold(){ printf '\033[1m%s\033[0m\n' "$1"; }
ok(){   printf '  \033[32m✓\033[0m %s\n' "$1"; }
info(){ printf '  • %s\n' "$1"; }
warn(){ printf '  \033[33m!\033[0m %s\n' "$1"; }
pause(){ read -r -p "Press Return to close this window… " _ || true; }
die(){ printf '\033[31merror:\033[0m %s\n' "$1" >&2; pause; exit 1; }

env_val(){ grep -E "^$1=" "$ENV_FILE" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"' || true; }

[[ -f "$ENV_FILE" ]] || die "backend/.env not found — run ./setup.sh first."
PORT="$(env_val PORT)"; PORT="${PORT:-8787}"
TOKEN="$(env_val PINCH_TOKEN)"
DOMAIN="$(env_val PINCH_NGROK_DOMAIN)"
[[ -n "${TOKEN//[[:space:]]/}" ]]  || die "PINCH_TOKEN empty in backend/.env — run ./setup.sh."
[[ -n "${DOMAIN//[[:space:]]/}" ]] || die "PINCH_NGROK_DOMAIN empty in backend/.env — set your ngrok static domain."

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

# --- 2. ngrok tunnel on the STABLE domain (reuse if live, else start) --------
command -v ngrok >/dev/null 2>&1 || die "ngrok not found — brew install ngrok."
URL="https://$DOMAIN"
skip='ngrok-skip-browser-warning: 1'
if pgrep -f "ngrok http $PORT" >/dev/null 2>&1 \
   && curl -fsS --max-time 8 -H "$skip" "$URL/health" >/dev/null 2>&1; then
  ok "reusing the live ngrok tunnel ($DOMAIN)"
else
  # ngrok free allows ONE agent session — clear a dead/half-open one first.
  pkill -f "ngrok http $PORT" 2>/dev/null || true
  : > "$NGROK_LOG"
  nohup ngrok http "$PORT" --url="$URL" --log="$NGROK_LOG" --log-format=logfmt >/dev/null 2>&1 &
  for _ in $(seq 1 40); do curl -fsS --max-time 8 -H "$skip" "$URL/health" >/dev/null 2>&1 && break; sleep 0.5; done
  curl -fsS --max-time 8 -H "$skip" "$URL/health" >/dev/null 2>&1 \
    && ok "tunnel up on $DOMAIN" \
    || die "ngrok did not come up — see $NGROK_LOG (authed? run: ngrok config add-authtoken <token>)"
fi

# --- 3. reference (URL is baked into the build; shown only if it ever resets) -
WSS="wss://$DOMAIN"
echo
bar="────────────────────────────────────────────────────────"
bold "Watch → Settings (baked into the build; re-enter only if it ever resets):"
printf '\033[36m%s\033[0m\n' "$bar"
printf '  URL    \033[1m%s\033[0m\n' "$WSS"
printf '  TOKEN  \033[1m%s\033[0m\n' "$TOKEN"
printf '\033[36m%s\033[0m\n' "$bar"
echo
ok "Tether is live on a STABLE URL. Close this window and walk away —"
info "it keeps serving while the Mac is logged in + awake."
info "Logs: $BACKEND_LOG · $NGROK_LOG"
echo
pause
