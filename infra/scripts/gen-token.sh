#!/usr/bin/env bash
# Thin wrapper around gen-token.mjs so you can `infra/scripts/gen-token.sh`.
# Passes all args through (e.g. --raw).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v node >/dev/null 2>&1; then
  echo "error: node not found on PATH. Install Node 20+ first." >&2
  exit 1
fi

exec node "$SCRIPT_DIR/gen-token.mjs" "$@"
