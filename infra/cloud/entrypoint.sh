#!/usr/bin/env bash
# Pinch cloud entrypoint.
# 1. Clone/sync each repo listed in $REPOS into /workspace using $GITHUB_TOKEN.
# 2. Point the backend's allowlist at those clones.
# 3. Start the WebSocket server.
#
# Env (set via `fly secrets set ...`):
#   REPOS         space- or comma-separated GitHub repos to make available.
#                 Each item is "owner/name" or a full https URL, optionally with
#                 a branch:  owner/name@branch
#   GITHUB_TOKEN  PAT (or fine-grained token) with repo read/write for cloning
#                 and pushing back. Used only to build the clone URL.
#   ANTHROPIC_API_KEY, PINCH_TOKEN   required by the backend itself.
set -euo pipefail

WORKSPACE="${WORKSPACE:-/workspace}"
mkdir -p "$WORKSPACE"

# Identity for any commits the agent makes (push-back flow).
git config --global user.name  "${GIT_AUTHOR_NAME:-Pinch Agent}"
git config --global user.email "${GIT_AUTHOR_EMAIL:-pinch-agent@users.noreply.github.com}"
git config --global --add safe.directory '*'

clone_or_update() {
  local spec="$1"
  local ref="" repo="$spec"

  # Split optional @branch.
  if [[ "$spec" == *"@"* && "$spec" != http*"@"* ]]; then
    repo="${spec%@*}"
    ref="${spec##*@}"
  fi

  # Build an authenticated https URL.
  local url name
  if [[ "$repo" == http*://* ]]; then
    # Inject the token into an https URL: https://x-access-token:TOKEN@host/...
    url="$(printf '%s' "$repo" | sed -E "s#https://#https://x-access-token:${GITHUB_TOKEN}@#")"
    name="$(basename "${repo%.git}")"
  else
    url="https://x-access-token:${GITHUB_TOKEN}@github.com/${repo}.git"
    name="$(basename "$repo")"
  fi

  local dest="$WORKSPACE/$name"
  if [[ -d "$dest/.git" ]]; then
    echo "[pinch] updating $name"
    git -C "$dest" remote set-url origin "$url"
    git -C "$dest" fetch --all --prune
    if [[ -n "$ref" ]]; then
      git -C "$dest" checkout "$ref"
      git -C "$dest" pull --ff-only origin "$ref" || true
    else
      git -C "$dest" pull --ff-only || true
    fi
  else
    echo "[pinch] cloning $name"
    if [[ -n "$ref" ]]; then
      git clone --branch "$ref" "$url" "$dest"
    else
      git clone "$url" "$dest"
    fi
  fi
}

if [[ -n "${REPOS:-}" ]]; then
  if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    echo "[pinch] error: REPOS set but GITHUB_TOKEN missing." >&2
    echo "        fly secrets set GITHUB_TOKEN=..." >&2
    exit 1
  fi
  # Allow comma or whitespace separation.
  normalized="${REPOS//,/ }"
  projects=""
  for spec in $normalized; do
    [[ -z "$spec" ]] && continue
    clone_or_update "$spec"
    name="$(basename "${spec%@*}")"; name="${name%.git}"
    projects="${projects:+$projects,}$WORKSPACE/$name"
  done
  # Build the allowlist from exactly what we cloned (overrides image default).
  export PINCH_PROJECTS="$projects"
  echo "[pinch] PINCH_PROJECTS=$PINCH_PROJECTS"
else
  echo "[pinch] no REPOS set; PINCH_PROJECTS=${PINCH_PROJECTS:-/workspace}"
fi

echo "[pinch] starting backend on :${PORT:-8787}"
exec node dist/index.js
