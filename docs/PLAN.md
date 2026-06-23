# Pinch — Claude Code on your wrist

**Codename:** Pinch (provisional — the double-tap pinch gesture is the signature interaction). Rename freely.

**Goal:** Drive a full Claude Code session from an Apple Watch Ultra. Voice in, response read aloud, approve/decline edits, full autonomy including a "dangerously skip permissions" mode — and it works over cellular from anywhere, not just LAN.

This doc is the autonomous build plan + the decisions made while you were out. Read `docs/DECISIONS.md` for the rationale behind each choice and `docs/STATUS.md` for what's done vs what needs you.

---

## The shape of it

Three pieces talking over one small message protocol (two transports — HTTP for
the watch, a WebSocket for the simulator — carrying the same message shapes):

```
┌─────────────────┐    HTTPS + poll over     ┌──────────────────────────┐
│  Apple Watch    │  ◄── cellular/internet ──►│  Pinch backend (Node/TS) │
│  Ultra (SwiftUI)│      (public TLS URL)     │  ── Claude Agent SDK ──┐ │
│                 │                           │   runs in your repo    │ │
│  voice • crown  │                           │   Bash/Edit/Write/...  │ │
│  double-tap •   │                           │                        │ │
│  shake • taps   │                           │   your projects ◄──────┘ │
└─────────────────┘                           └──────────────────────────┘
        ▲                                                  ▲
        │                                                  │
   reads aloud (TTS),                            public endpoint via
   shows diffs, confirms                         a stable ngrok domain
                                                 (works over cellular)
```

> The watch uses HTTP (`/api/*`) because watchOS refuses `URLSessionWebSocketTask`
> on the watch's network path; the browser simulator uses the WebSocket (`/ws`).

- **Backend** (`backend/`): a Node/TypeScript service wrapping the **Claude Agent SDK** — the same engine as the Claude Code CLI, so the watch gets the *same* tools and autonomy (Bash, Edit, Write, Read, Grep, ...). Exposes both a WebSocket (`/ws`, simulator) and an HTTP API (`/api/*`, watch) that stream assistant text, tool calls, and permission requests, and accept voice-transcribed messages, approve/decline decisions, mode changes, and cancels. Supports `bypassPermissions` ("dangerously skip permissions"). Appends a watch-orientation note to the system prompt so replies stay plain-text and brief.
- **Watch app** (`watch/`): native watchOS SwiftUI app. Voice dictation → message, double-tap to send, Digital Crown to scroll, Action button for push-to-talk, wrist-shake to cancel, taps to approve/decline. Reads responses aloud.
- **Protocol** (`packages/protocol/`): shared TypeScript types + `PROTOCOL.md` — the wire contract both sides implement.
- **Simulator** (`simulator/`): a browser-based watch face that speaks the exact same protocol. Lets us (and you) test the whole system end-to-end **without** Apple hardware or code signing. This is how the backend gets verified today.
- **Infra** (`infra/`): a stable **ngrok** free static domain (recommended) plus Cloudflare named-tunnel scaffolding, a double-click launcher (`start-pinch.command`), `launchd` agents, and a Fly.io cloud mode.

## Why this architecture (short version)

- **Agent SDK, not SSH-into-a-terminal:** SSH from a watch is fragile and gives you a raw TTY that's miserable to drive with a crown and three buttons. The Agent SDK gives us *structured* events (this is a tool call, this is a permission request, this is assistant text) which is exactly what a glanceable watch UI needs. Same autonomy as the CLI, far better UX surface.
- **Backend runs where your repos are (your Mac), exposed via a tunnel:** this keeps your real, possibly-uncommitted projects reachable, and a stable ngrok domain (or your own Cloudflare tunnel) gives a public URL the watch hits over cellular. A cloud mode (clone from GitHub on a VM) is also supported for when your Mac is off — same backend, different working dir, pushed code only.
- **One thin protocol:** because the watch is a constrained client, all the smarts live in the backend. The watch just renders events and sends 6 message types.

## Gesture / control map (Apple Watch Ultra)

| Control | Action |
|---|---|
| **Double-tap (pinch)** | **Send the current message** (as requested) |
| Tap mic / Action button | Start/stop push-to-talk dictation |
| Digital Crown rotate | Scroll transcript / scrub diff hunks |
| Digital Crown press | (system) — back |
| **Wrist shake** | **Cancel / stop** the in-flight turn (CoreMotion) |
| Tap ✓ / ✗ on a permission card | Approve / decline an edit or command |
| Long-press / Action button hold | Toggle **dangerously-skip-permissions** (guarded confirm) |
| Side button | (system) |

(Final bindings depend on what's actually exposed to third-party apps in current watchOS — being verified by the watchOS research agent; see DECISIONS.)

## Build order (autonomous)

1. ✅ Find repo, clone, scaffold monorepo, push. (version control live)
2. ⏳ Research (3 Opus agents, parallel): watchOS client APIs, Claude Agent SDK, connectivity/deploy.
3. Write the wire protocol (`PROTOCOL.md` + shared types) from research.
4. Build in parallel (Opus agents, one dir each): backend, watch app, simulator + infra.
5. Integrate: `npm install`, typecheck, run backend + simulator end-to-end, verify.
6. Write STATUS + setup docs. Push throughout.

## What needs you (can't be done autonomously)

- **Anthropic auth** in `backend/.env` — `PINCH_AUTH=subscription` (default) uses your Mac's Claude Code login (no key); `apikey` mode uses `ANTHROPIC_API_KEY`.
- **Xcode + an Apple Developer account** to sign and install the watch app on your Ultra. Set your Team + bundle id in `watch/project.yml`, then `xcodegen generate`. Signing/installing is interactive and needs your account.
- A **reserved ngrok free static domain** (`PINCH_NGROK_DOMAIN`) for the stable public URL — one-time `ngrok config add-authtoken …` + reserve a domain in the dashboard.

Everything else is wired so you fill in three secrets and run two commands. See `docs/STATUS.md`.
