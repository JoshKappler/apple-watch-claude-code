# Pinch — Claude Code on your wrist

Drive a full Claude Code session from an Apple Watch Ultra. Talk to it, hear it talk back, approve or decline its edits, and run with full autonomy — including a "dangerously skip permissions" mode — over cellular, from anywhere.

> Codename **Pinch**: you send a message with the watch's double-tap pinch gesture. Provisional name; rename freely.

## How it works

A small **backend** wraps the [Claude Agent SDK](https://docs.claude.com) and runs inside your real git repos, so the watch gets the same tools and autonomy as the Claude Code CLI (Bash, Edit, Write, Read, Grep, …). It exposes a **WebSocket** that streams assistant text, tool calls, and permission requests. A native **watchOS app** is a thin client: voice in, response read aloud, gestures to send/approve/cancel. A public URL via **Cloudflare Tunnel** makes it reachable over the watch's cellular connection — not just Wi-Fi.

```
Watch (SwiftUI) ⇄ WSS/cellular ⇄ Cloudflare Tunnel ⇄ Backend (Agent SDK) ⇄ your repos
```

## Repo layout

| Path | What |
|---|---|
| `backend/` | Node/TypeScript service: Agent SDK + WebSocket server. The brain. |
| `watch/` | watchOS SwiftUI app (Xcode project). The remote control. |
| `packages/protocol/` | Shared wire protocol: TS types + `PROTOCOL.md`. The contract. |
| `simulator/` | Browser "watch" that speaks the protocol — test end-to-end with no Apple hardware. |
| `infra/` | Cloudflare Tunnel config + `launchd` agent to keep it all running. |
| `docs/` | `PLAN.md`, `DECISIONS.md`, `STATUS.md`. |

## Quick start

**Easiest (remote, no sign-in):** double-click `infra/start-pinch.command` (or copy it to your
Desktop for a one-click icon). It brings the backend + an anonymous Cloudflare quick tunnel up,
reuses them if already running, and prints the `wss://…/ws` URL + token to enter on the watch.

See `docs/STATUS.md` for the current state and the exact secrets + commands you need. TL;DR:

```bash
# 1. backend
cd backend && cp .env.example .env   # add ANTHROPIC_API_KEY + a PINCH_TOKEN
npm install && npm run dev

# 2. test it without a watch
cd ../simulator && npm run dev        # open the browser watch, talk to your repo

# 3. go public (cellular) — one-time cloudflared login, then:
infra/start-tunnel.sh
```

Status, design rationale, and what still needs you: **`docs/STATUS.md`** and **`docs/DECISIONS.md`**.
