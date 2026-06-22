# Cloud mode (Fly.io, always-on)

Run the Pinch backend on a small always-on Fly.io Machine so the watch can reach
it **without your Mac being awake**. The Machine clones your GitHub repos into a
persistent volume at boot, runs the Agent SDK against them, and serves the same
WebSocket on a public `wss://` URL.

```
Watch ⇄ wss://pinch-<you>.fly.dev/ws ⇄ Fly edge (TLS) ⇄ Machine :8787 ⇄ /workspace/<repo>
```

## Why not Vercel?

Vercel (and serverless generally) has **no persistent WebSocket / long-running
process** — even with Fluid Compute, functions are request-scoped and suspend.
Pinch needs a process that holds an open WS for the whole session and keeps an
agent alive. Fly Machines are full VMs that stay up, so they fit; Vercel does
not. Use Cloudflare Tunnel + your Mac, or Fly — not Vercel.

## The tradeoff (read this)

Cloud mode only sees **pushed** code. The agent operates on a *fresh clone* from
GitHub, not your Mac's working tree, so uncommitted/unpushed local changes are
invisible to it. In exchange you get always-on with no Mac.

| | Mac + Cloudflare Tunnel | Cloud (Fly) |
|---|---|---|
| Sees uncommitted local changes | yes | no (pushed only) |
| Always on | only while Mac awake | yes |
| Cost | free | ~$2–20/mo |

If you want the agent's work back on your Mac, it pushes a branch and you open a
PR / pull it down (see "Getting changes back").

## Setup

From the **repo root** (the Docker build context is the root):

```bash
# 1. One-time: create the Fly app from the provided config (don't deploy yet).
#    Edit infra/cloud/fly.toml first: set `app = "pinch-<you>"`.
fly launch --no-deploy --copy-config --name pinch-<you>

# 2. Persistent volume for the cloned repos (survives restarts/deploys).
fly volumes create pinch_workspace --size 10 --region <region>

# 3. Secrets — never commit these.
fly secrets set \
  ANTHROPIC_API_KEY=sk-ant-... \
  PINCH_TOKEN="$(node infra/scripts/gen-token.mjs --raw)" \
  GITHUB_TOKEN=ghp_... \
  REPOS="owner/repo1 owner/repo2"      # space- or comma-separated; supports owner/repo@branch

# 4. Deploy.
fly deploy
```

Your endpoint for the watch/sim is:

```
wss://pinch-<you>.fly.dev/ws
```

with the same `PINCH_TOKEN` as the bearer.

## `REPOS` format

- `owner/name` — clones the default branch
- `owner/name@branch` — clones a specific branch
- a full `https://github.com/owner/name.git` URL also works

`entrypoint.sh` clones each into `/workspace/<name>`, then sets
`PINCH_PROJECTS` to exactly those paths (the backend's allowlist). On restart it
fetches/pulls instead of re-cloning.

## Getting changes back

The agent edits the clone in `/workspace`. To get work onto your Mac:

1. Have the agent commit on a feature branch and push:
   ```
   git checkout -b pinch/<task>
   git add -A && git commit -m "..."
   git push -u origin pinch/<task>
   ```
   (The `GITHUB_TOKEN` is already in the clone's remote URL, so push works.)
2. Open a PR on GitHub and review/merge, or `git fetch && git checkout
   pinch/<task>` on your Mac.

Keep `GITHUB_TOKEN` scoped to just the repos in `REPOS`, with the minimum
permissions needed to clone and push.

## Operations

```bash
fly logs                          # tail logs
fly status                        # machine + volume state
fly ssh console                   # shell into the Machine (/workspace, /app/backend)
fly secrets unset PINCH_TOKEN     # part of the kill-switch (see infra/SECURITY.md)
fly machine stop                  # hard kill-switch: stop the Machine
```
