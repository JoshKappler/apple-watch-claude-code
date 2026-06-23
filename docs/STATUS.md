# Status — what's built and how it actually runs

Current state of Pinch on `main`. The system is built, verified, and in daily use
driving real Claude Code sessions from an Apple Watch Ultra over cellular.

## One line

The backend wraps the Claude Agent SDK against your local repos; a stable ngrok
domain exposes it; the watch app drives it over HTTP from the wrist. To run your
own, you do three things only you can: set `PINCH_PROJECT_ROOTS` + auth, reserve
an ngrok domain, and sign the watch app in Xcode with your Apple Team.

---

## What's built and verified

| Piece | State | Notes |
|---|---|---|
| **Wire protocol** (`packages/protocol`) | Done | Zod schemas + `PROTOCOL.md`; Swift mirror in `watch/Sources/Protocol.swift`. |
| **Backend** (`backend`) | Done + verified | Two transports on one session model: WebSocket `/ws` (simulator) and HTTP `/api/*` (watch). Subscription auth by default. |
| **Simulator** (`simulator`) | Done + verified | Browser "watch" over the WS path; the keyless end-to-end test rig. |
| **watchOS app** (`watch`) | Done | Single-target watchOS 11 SwiftUI app; generated via XcodeGen; HTTP transport with a durable prompt outbox + session resume. |
| **Infra** (`infra`) | Done | ngrok stable domain (primary), Cloudflare named-tunnel scaffolding, Fly.io cloud mode, launchd, token gen, `SECURITY.md`. |

## How it runs now

- **Transport.** The physical watch uses **HTTP request/response + a ~1.2s
  poll** against `/api/*` (`backend/src/httpApi.ts`) — watchOS refuses
  `URLSessionWebSocketTask` on the watch's network path. The Swift client class is
  still named `WSClient` for historical reasons; it is HTTP. The browser simulator
  uses the WebSocket at `/ws`. Both share the session map, agent wiring, event
  log, resume rule, and idle sweep via `sessionRegistry.ts`.
- **Tunnel.** A **stable ngrok free static domain** (`PINCH_NGROK_DOMAIN`). The
  URL never changes, so restarts don't strand the baked watch build. Bring it up
  by double-clicking `infra/start-pinch.command` (idempotent, detached).
- **Auth to Anthropic.** `PINCH_AUTH=subscription` (default) uses the Mac's Claude
  Code login (Claude Max/Pro keychain) — no API key. `apikey` mode uses
  `ANTHROPIC_API_KEY`.
- **Durable delivery.** Prompts go into a persisted outbox on the watch, removed
  only on a confirmed 2xx; the backend dedups by client `promptId` so a retry
  can't double-run a turn. A message sent during an LTE handoff is held and
  delivered on reconnect rather than lost.
- **Durable resume.** Session records persist to `backend/.pinch-sessions.json`,
  so a backend restart or the idle sweep doesn't wipe Claude's context — the
  session is revived with the SDK transcript reloaded.
- **Watch-aware agent.** Every session appends a watch-orientation note to the
  Claude Code system prompt (`WATCH_SYSTEM_APPEND` in `backend/src/session.ts`):
  replies are read aloud and shown on a tiny screen, so the agent writes plain
  text (no Markdown), keeps it brief, and offers choices as short numbered prose.
  This shapes communication only; the coding work is unchanged.

## Try it right now (no watch, no API key)

```bash
npm install
PINCH_MOCK=1 PINCH_TOKEN=test-token npm run dev      # backend, mock agent
# in another shell:
PINCH_TOKEN=test-token npm run smoke                  # full round-trip over WS
npm run sim                                            # or click around the browser watch
```

---

## What needs you

1. **Auth + projects.** Run `./setup.sh` (generates `PINCH_TOKEN`, creates
   `Secrets.swift`), then set `PINCH_PROJECT_ROOTS` in `backend/.env`. Subscription
   auth is the default and needs no key — just be logged in via the `claude` CLI.
2. **A reserved ngrok domain.** `ngrok config add-authtoken …`, reserve a free
   static domain, set `PINCH_NGROK_DOMAIN`.
3. **Xcode + your Apple Team.** Change `DEVELOPMENT_TEAM` and the bundle id in
   `watch/project.yml`, then `xcodegen generate && open Pinch.xcodeproj` and Run on
   your watch. Details: `watch/README.md`.
4. **(One-time, on the watch) Action button → dictation.** Shortcuts app → the
   "Speak a message in Pinch" shortcut → Settings → Action Button → First Press.
5. **(Optional) APNs key** to make the "long task finished" push live. Stubbed in
   `watch/Sources/PushRegistration.swift`.

Full walkthrough: **`docs/SETUP.md`**.

---

## Control map (Apple Watch Ultra)

| Control | Action |
|---|---|
| **Double-tap (pinch)** | **Send message** (`.handGestureShortcut(.primaryAction)`, Series 9 / Ultra 2+); on-screen Send is the fallback |
| **Action button** / mic | Start dictation (Apple system dictation) |
| **Digital Crown** | Scroll transcript · move the text cursor · highlight menu options |
| **Crown — rotate to confirm** | Permission gate: right = allow, left = deny (springs back) |
| **Crown — pause to commit** | Mode / project menus: rotate to highlight, dwell to select |
| Swipe ← in editor | Delete the previous word |
| **Wrist shake** | **Cancel** the in-flight turn |
| Tap ✓ / ✗ · tap a row | Mirror the crown decision/selection |

## Honest caveats (watchOS realities)

- **Double-tap is Series 9 / Ultra 2+ only.** Elsewhere the on-screen Send button
  is the path; the app feature-detects and degrades.
- **No crown press for apps** — confirm/select is built from crown rotation.
- **Voice is Apple system dictation**, not an always-on listener
  (`SFSpeechRecognizer` doesn't function on watchOS).
- **TTS can be silent without AirPods** — every spoken reply also fires a haptic.
- **No background connection** — foreground only; reconnect + resume on reopen.
  APNs is the re-engagement path and is stubbed.
- **Agent SDK is pre-1.0** — its surface can move; the version is pinned.
- **This is remote code execution as a service.** The bearer token is the only
  lock. Treat it like an SSH key. See `infra/SECURITY.md`.

## Cost shape

Mac + ngrok = **$0** infra (you pay for the watch's cellular plan and your
Anthropic usage, or nothing extra on a Claude subscription). Always-on cloud mode
(Fly.io) is ~$2–20/mo and only sees pushed code.

## Repo map

`backend/` server · `watch/` watchOS app · `simulator/` browser test client ·
`packages/protocol/` wire contract · `infra/` deploy · `docs/` PLAN, DECISIONS,
SETUP, STATUS · `scripts/smoke-test.mjs` verifier.
