#!/usr/bin/env bash
# pinch-up — start a remote Pinch session your watch can reach, in one command.
#
# What it does:
#   1. Builds the protocol + backend (so it runs from dist, no tsx needed).
#   2. Starts the backend, scoped to whatever PINCH_PROJECT_ROOTS / PINCH_PROJECTS
#      in backend/.env say (point it at your projects folder → every repo shows up
#      on the watch, recency-sorted).
#   3. Opens a public tunnel so the watch can connect over cellular/anywhere:
#        - cloudflared if a named-tunnel config exists (stable URL), else
#        - ngrok (stable if you pass PINCH_NGROK_DOMAIN, otherwise an ephemeral URL).
#   4. Prints the exact  wss://<host>/ws  URL + PINCH_TOKEN to punch into the watch.
#
# Ctrl-C tears down both the backend and the tunnel together.
#
# Env overrides:
#   PINCH_TUNNEL=cloudflared|ngrok|none   force a tunnel (default: auto-detect)
#   PINCH_NGROK_DOMAIN=foo.ngrok.app      reserved ngrok domain → stable, "findable" URL
#   PINCH_TUNNEL_NAME=pinch               cloudflared named tunnel (default: pinch)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"
ENV_FILE="$REPO_ROOT/backend/.env"

bold()  { printf '\033[1m%s\033[0m\n' "$1"; }
ok()    { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn()  { printf '  \033[33m!\033[0m %s\n' "$1"; }
info()  { printf '  • %s\n' "$1"; }
die()   { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }

# --- read a KEY=value from backend/.env (no surrounding quotes expected) ---------
env_val() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"' || true; }

[[ -f "$ENV_FILE" ]] || die "backend/.env not found. Run ./setup.sh first."
command -v node >/dev/null 2>&1 || die "node not found. Install Node 20+."

PORT="$(env_val PORT)";        PORT="${PORT:-8787}"
TOKEN="$(env_val PINCH_TOKEN)"
[[ -n "${TOKEN//[[:space:]]/}" ]] || die "PINCH_TOKEN is empty in backend/.env. Run ./setup.sh."

bold "Pinch — starting a remote session"
echo

# --- 1. build -------------------------------------------------------------------
bold "1. Build"
npm run --silent build --workspace @pinch/protocol
npm run --silent build --workspace @pinch/backend
ok "protocol + backend built"
echo

# --- background process bookkeeping (kill everything on exit) --------------------
PIDS=()
cleanup() {
  echo
  info "shutting down…"
  for pid in "${PIDS[@]:-}"; do
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
  done
}
trap cleanup EXIT INT TERM

# --- 2. backend -----------------------------------------------------------------
bold "2. Backend"
( cd "$REPO_ROOT/backend" && node dist/index.js ) &
BACKEND_PID=$!
PIDS+=("$BACKEND_PID")

# Wait for the port to accept connections (max ~10s).
for _ in $(seq 1 50); do
  if node -e "require('net').connect($PORT,'127.0.0.1').on('connect',()=>process.exit(0)).on('error',()=>process.exit(1))" 2>/dev/null; then
    break
  fi
  kill -0 "$BACKEND_PID" 2>/dev/null || die "backend exited during startup (check its logs above)."
  sleep 0.2
done
ok "backend listening on 127.0.0.1:$PORT/ws"
echo

# --- 3. pick a tunnel -----------------------------------------------------------
TUNNEL="${PINCH_TUNNEL:-auto}"
CF_CONFIG="${PINCH_TUNNEL_CONFIG:-$HOME/.cloudflared/config.yml}"
if [[ "$TUNNEL" == "auto" ]]; then
  if [[ -f "$CF_CONFIG" ]]; then TUNNEL="cloudflared"
  elif command -v ngrok >/dev/null 2>&1; then TUNNEL="ngrok"
  else TUNNEL="none"; fi
fi

PUBLIC_WSS=""

start_ngrok() {
  command -v ngrok >/dev/null 2>&1 || die "ngrok not found. brew install ngrok (or set PINCH_TUNNEL=none)."
  local args=(http "$PORT" --log=stdout)
  if [[ -n "${PINCH_NGROK_DOMAIN:-}" ]]; then args=(http "$PORT" --domain="$PINCH_NGROK_DOMAIN" --log=stdout); fi
  ngrok "${args[@]}" >/tmp/pinch-ngrok.log 2>&1 &
  PIDS+=("$!")
  # ngrok exposes a local API with the public URL once it's up.
  local url=""
  for _ in $(seq 1 50); do
    url="$(curl -s http://127.0.0.1:4040/api/tunnels 2>/dev/null \
      | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const t=JSON.parse(s).tunnels||[];const h=t.find(x=>x.proto==="https")||t[0];process.stdout.write(h?h.public_url:"")}catch{}})' 2>/dev/null)"
    [[ -n "$url" ]] && break
    sleep 0.2
  done
  [[ -n "$url" ]] || die "ngrok did not report a public URL. See /tmp/pinch-ngrok.log (is it authed? run: ngrok config add-authtoken <token>)."
  PUBLIC_WSS="wss://${url#https://}/ws"
}

start_cloudflared() {
  command -v cloudflared >/dev/null 2>&1 || die "cloudflared not found. brew install cloudflared."
  [[ -f "$CF_CONFIG" ]] || die "cloudflared config not found at $CF_CONFIG (see infra/cloudflared/README.md)."
  cloudflared tunnel --config "$CF_CONFIG" run "${PINCH_TUNNEL_NAME:-pinch}" >/tmp/pinch-cloudflared.log 2>&1 &
  PIDS+=("$!")
  # The hostname is defined in the cloudflared config (ingress: hostname:).
  local host
  host="$(grep -E '^[[:space:]]*hostname:' "$CF_CONFIG" | head -n1 | awk '{print $2}')"
  [[ -n "$host" ]] || die "could not read hostname from $CF_CONFIG"
  PUBLIC_WSS="wss://${host}/ws"
  sleep 2  # give the edge a moment to register the connection
}

bold "3. Tunnel ($TUNNEL)"
case "$TUNNEL" in
  ngrok)       start_ngrok ;;
  cloudflared) start_cloudflared ;;
  none)        PUBLIC_WSS="ws://$(ipconfig getifaddr en0 2>/dev/null || echo 127.0.0.1):$PORT/ws" ;;
  *)           die "unknown PINCH_TUNNEL=$TUNNEL (use cloudflared|ngrok|none)" ;;
esac
ok "tunnel up"
echo

# --- 4. tell the user what to type into the watch -------------------------------
bar="────────────────────────────────────────────────────────"
bold "On your watch → Settings, enter:"
printf '\033[36m%s\033[0m\n' "$bar"
printf '  URL    \033[1m%s\033[0m\n' "$PUBLIC_WSS"
printf '  TOKEN  \033[1m%s\033[0m\n' "$TOKEN"
printf '\033[36m%s\033[0m\n' "$bar"
echo
if [[ "$TUNNEL" == "ngrok" && -z "${PINCH_NGROK_DOMAIN:-}" ]]; then
  warn "This ngrok URL changes every run. For a permanent, 'findable' URL:"
  info "reserve a free static domain at dashboard.ngrok.com, then re-run with:"
  info "PINCH_NGROK_DOMAIN=your-name.ngrok-free.app ./pinch-up.sh"
fi
if [[ "$TUNNEL" == "none" ]]; then
  warn "No tunnel — this LAN URL only works on the same WiFi, and watchOS may"
  info "block plaintext ws://. Use ngrok/cloudflared for a real remote session."
fi
echo
info "Leave this running. Press Ctrl-C to stop the backend + tunnel."
echo

# Keep the script in the foreground tied to the backend's life.
wait "$BACKEND_PID"
