#!/usr/bin/env bash
# Pinch bootstrap. Friendly, idempotent, non-destructive.
# - Checks for node + cloudflared
# - Copies backend/.env.example -> backend/.env if absent (NEVER overwrites)
# - Generates a PINCH_TOKEN and drops it in if the .env's PINCH_TOKEN is empty
# - Prints next steps
#
# Safe to run repeatedly. It will not clobber an existing .env or an existing token.
set -euo pipefail

# Resolve the repo root from this script's location (path may contain spaces).
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

BACKEND_DIR="$REPO_ROOT/backend"
ENV_FILE="$BACKEND_DIR/.env"
ENV_EXAMPLE="$BACKEND_DIR/.env.example"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
info() { printf '  • %s\n' "$1"; }

bold "Pinch setup"
echo

# --- 1. tool checks ---------------------------------------------------------
bold "1. Checking tools"
if command -v node >/dev/null 2>&1; then
  ok "node $(node --version)"
  node_major="$(node -p 'process.versions.node.split(".")[0]')"
  if [[ "$node_major" -lt 20 ]]; then
    warn "Node 20+ recommended (found $(node --version))."
  fi
else
  warn "node not found. Install Node 20+ before running the backend."
fi

if command -v cloudflared >/dev/null 2>&1; then
  ok "cloudflared present"
else
  warn "cloudflared not found (only needed for the Cloudflare Tunnel path)."
  info "Install with: brew install cloudflared"
fi
echo

# --- 2. backend/.env --------------------------------------------------------
bold "2. backend/.env"
if [[ -f "$ENV_FILE" ]]; then
  ok "backend/.env already exists — leaving it untouched."
else
  if [[ -f "$ENV_EXAMPLE" ]]; then
    cp "$ENV_EXAMPLE" "$ENV_FILE"
    chmod 600 "$ENV_FILE" 2>/dev/null || true
    ok "Created backend/.env from .env.example (chmod 600)."
  else
    warn "backend/.env.example not found; cannot create backend/.env."
  fi
fi
echo

# --- 3. PINCH_TOKEN ---------------------------------------------------------
bold "3. PINCH_TOKEN"
GEN_TOKEN="$REPO_ROOT/infra/scripts/gen-token.mjs"
if [[ -f "$ENV_FILE" ]] && command -v node >/dev/null 2>&1 && [[ -f "$GEN_TOKEN" ]]; then
  # Is PINCH_TOKEN present and non-empty?
  current="$(grep -E '^PINCH_TOKEN=' "$ENV_FILE" | head -n1 | cut -d= -f2- || true)"
  if [[ -n "${current//[[:space:]]/}" ]]; then
    ok "PINCH_TOKEN already set — leaving it as is."
  else
    token="$(node "$GEN_TOKEN" --raw)"
    if grep -qE '^PINCH_TOKEN=' "$ENV_FILE"; then
      # Replace the empty assignment in place (portable: rewrite via a temp file).
      tmp="$(mktemp)"
      # shellcheck disable=SC2016
      awk -v tok="$token" '
        /^PINCH_TOKEN=/ { print "PINCH_TOKEN=" tok; next }
        { print }
      ' "$ENV_FILE" > "$tmp" && mv "$tmp" "$ENV_FILE"
    else
      printf 'PINCH_TOKEN=%s\n' "$token" >> "$ENV_FILE"
    fi
    chmod 600 "$ENV_FILE" 2>/dev/null || true
    ok "Generated a PINCH_TOKEN and wrote it to backend/.env."
    info "Use the SAME token in the watch app / simulator."
  fi
else
  warn "Skipped token generation (need node + backend/.env + infra/scripts/gen-token.mjs)."
fi
echo

# --- 4. reminders -----------------------------------------------------------
bold "4. Still needed in backend/.env"
info "ANTHROPIC_API_KEY=...   (or set PINCH_MOCK=1 to run without the SDK)"
info "PINCH_PROJECTS=...      (comma-separated ABSOLUTE repo paths the agent may edit)"
echo

# --- next steps -------------------------------------------------------------
bold "Next steps"
cat <<'EOF'
  1. Edit backend/.env: add ANTHROPIC_API_KEY and PINCH_PROJECTS.
  2. Install deps:        npm install
  3. Run the backend:     npm run dev
  4. Test with the sim:   npm run sim        (open the browser "watch")
  5. Go public (cellular):
       - one-time:  see infra/cloudflared/README.md
                    (cloudflared login / create pinch / route dns)
       - then:      infra/start-tunnel.sh
                    (or infra/launchd/install-launchd.sh to keep it running)
  6. In the watch/sim, set URL = wss://agent.<yourdomain>/ws and the PINCH_TOKEN.

  Full walkthrough: docs/SETUP.md   •   Security: infra/SECURITY.md
EOF
