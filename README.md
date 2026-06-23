# Pinch — Claude Code on your Apple Watch

Drive a real Claude Code session from an Apple Watch over cellular. Dictate a
message, hear the reply read back, approve or decline edits with the Digital
Crown, flip into "dangerously skip permissions" mode, and let an agent work in
your actual git repos — from anywhere, with your phone in your pocket.

> The name comes from the gesture: you send a message with the watch's hardware
> double-tap (pinch). It's a working codename — rename it freely.

This is a **tether**, not a cloud product. The backend runs on *your* Mac,
against *your* local repos, and a tunnel makes it reachable from the watch. The
watch is a thin client. Nothing of your code leaves your machine except the
agent's text going to Anthropic, the same as the Claude Code CLI.

⚠️ **Read this once before you start.** When this is running, anyone who has your
URL **and** your token can make an agent run `bash` and edit files on your Mac.
The token is the only lock. Treat it like an SSH key. See
[`infra/SECURITY.md`](infra/SECURITY.md).

---

## How it works

```
Apple Watch (SwiftUI app)
   │   HTTPS request/response + ~1.2s poll
   │   Authorization: Bearer <PINCH_TOKEN>
   ▼
ngrok edge   ──►   ngrok agent   ──►   backend on localhost:8787
(your stable free domain)               (Node + Claude Agent SDK)
                                            │
                                            ▼
                                  your real git repos
                                  (PINCH_PROJECT_ROOTS)
```

- The **backend** wraps the [Claude Agent SDK](https://docs.claude.com/en/api/agent-sdk/overview)
  and runs inside your repos, so the watch gets the same tools and autonomy as
  the CLI (Bash, Edit, Write, Read, Grep, …). It authenticates to Anthropic with
  your **Claude Max subscription** by default — no API key required.
- The **watch app** is a native watchOS client. It talks to the backend over
  **HTTP** (request/response + a short poll loop), not WebSockets — watchOS
  refuses `URLSessionWebSocketTask` on the watch's cellular path, so HTTP is the
  only transport that actually works on the wrist.
- A **tunnel** (ngrok free static domain) gives the backend a stable public URL
  the watch can reach over LTE. The domain never changes, so the URL baked into
  the watch build keeps working across restarts.
- The **browser simulator** speaks the same protocol over the WebSocket (`/ws`)
  path, so you can test the whole loop with no Apple hardware.

---

## What you need

**On the Mac (the backend):**
- macOS with **Node 20+**
- A **Claude subscription** (Max/Pro) logged in via the Claude Code CLI — or an
  `ANTHROPIC_API_KEY` if you'd rather pay per token
- A free **[ngrok](https://ngrok.com)** account (for the public URL)

**For the watch app:**
- **Xcode 16+** (ships the watchOS 11 SDK)
- **[XcodeGen](https://github.com/yonik/XcodeGen)** — `brew install xcodegen`
- An **Apple Developer account** (free tier is fine for personal on-device installs)
- An **Apple Watch on watchOS 11+**. Any watchOS 11 watch works; the hardware
  double-tap "Send" gesture needs **Series 9 / Ultra 2 or later**. Cellular is
  what makes it useful away from home, but Wi-Fi works too.

You can do the entire backend half and test it in the browser before you ever
touch Xcode.

---

## Setup

There are three parts: **backend**, **tunnel**, **watch**. Do them in order.

### Part 1 — Backend on your Mac

```bash
git clone https://github.com/JoshKappler/apple-watch-claude-code-.git pinch
cd pinch
./setup.sh          # creates backend/.env, generates a PINCH_TOKEN, and
                    # creates watch/Sources/Secrets.swift with the token filled in
npm install
```

`setup.sh` is idempotent and never overwrites an existing `.env` or token. Now
open **`backend/.env`** and set the two things it can't guess:

```ini
# How the agent authenticates to Anthropic.
#   subscription = use the Claude Code login already on this Mac (default, no key)
#   apikey       = use ANTHROPIC_API_KEY below instead
PINCH_AUTH=subscription
ANTHROPIC_API_KEY=                      # only needed if PINCH_AUTH=apikey

# Generated for you by setup.sh. The watch must present the SAME value.
PINCH_TOKEN=<already filled in>

# WHICH REPOS THE WATCH CAN OPEN. Set at least one.
# Point this at a PARENT folder — every child repo shows up on the watch,
# recency-sorted, recomputed each time you open the picker (clone a repo, it
# just appears, no restart).
PINCH_PROJECT_ROOTS=/Users/you/Desktop/projects
# Optional: explicit absolute repo paths to also allow.
PINCH_PROJECTS=

PORT=8787
PINCH_MODEL=claude-opus-4-8
```

> If `PINCH_AUTH=subscription`, make sure you're logged in: run `claude` once in
> a terminal and complete the login. The backend reuses that keychain session.

**Test it with no watch and no key** to prove the plumbing works end to end:

```bash
# terminal 1 — backend in mock mode (scripted agent, no SDK, no key)
PINCH_MOCK=1 PINCH_TOKEN=dev-token npm run dev

# terminal 2 — the browser "watch"
npm run sim
```

In the simulator, connect to `ws://localhost:8787/ws` with token `dev-token`,
send a prompt, and watch the scripted turn stream in — including the permission
card you approve with a click. When that works, drop `PINCH_MOCK`, set
`PINCH_PROJECT_ROOTS`, and you have a real agent talking to your repos locally.

### Part 2 — Tunnel (stable ngrok domain)

This is what makes the backend reachable from the watch over cellular.

1. Create a free ngrok account, then authenticate the agent once:
   ```bash
   brew install ngrok
   ngrok config add-authtoken <your-token-from-the-ngrok-dashboard>
   ```
2. In the ngrok dashboard, **reserve a free static domain** (Domains → New
   Domain). You'll get something like `your-name-here.ngrok-free.dev`. It's
   free, permanent, and yours.
3. Put it in `backend/.env`:
   ```ini
   PINCH_NGROK_DOMAIN=your-name-here.ngrok-free.dev
   ```

That's it. ngrok free allows one agent session at a time, which is all you need.

### Part 3 — The watch app

The Xcode project is **generated** from `watch/project.yml` (it's gitignored, not
committed). Before generating, you have to point it at **your** Apple Developer
account — the committed `project.yml` has the original author's Team baked in and
you can't sign with it.

1. Edit `watch/project.yml`:
   ```yaml
   options:
     bundleIdPrefix: com.yourname.pinch        # change to a prefix you own
   targets:
     Pinch:
       settings:
         base:
           PRODUCT_BUNDLE_IDENTIFIER: com.yourname.pinch.watch   # change this
           DEVELOPMENT_TEAM: XXXXXXXXXX                          # YOUR team id
   ```
   Your Team ID is in [developer.apple.com](https://developer.apple.com/account)
   → Membership, or in Xcode → Settings → Accounts.

2. Generate and open the project:
   ```bash
   cd watch
   xcodegen generate          # reads project.yml → writes Pinch.xcodeproj
   open Pinch.xcodeproj
   ```

3. Point the watch at your backend. Edit **`watch/Sources/Secrets.swift`**
   (created by `setup.sh`, gitignored — never commit it):
   ```swift
   enum Secrets {
       static let serverURL = "wss://your-name-here.ngrok-free.dev"  // your ngrok domain
       static let token = "<your PINCH_TOKEN>"                       // already filled in by setup.sh
   }
   ```
   Enter the `wss://` URL — the app normalizes it and uses HTTPS under the hood.
   This value is just the default; you can also type/override it in the watch's
   Settings screen later.

4. In Xcode: pick your Apple Watch as the run destination and **Run**. The first
   on-device install needs you to trust your developer certificate on the watch
   (Watch app → General → VPN & Device Management).

### Part 4 — Launch and connect

Bring the backend + tunnel up with one command:

```bash
npm run build                 # build the backend once (the launcher runs from dist/)
infra/start-pinch.command     # or double-click it in Finder
```

`start-pinch.command` is idempotent and detached: it reuses a healthy backend and
a live tunnel, starts only what's missing, runs everything under `nohup` (close
the window and walk away — it keeps serving while the Mac is logged in and
awake), and prints the exact URL + token. Because the ngrok domain is stable, the
URL baked into the watch keeps working — you only ever re-enter it if you reset
the watch's settings.

Open the app on your watch, take your phone out of range (or turn Wi-Fi off to
prove cellular), and send a message. You're now driving an agent on your Mac from
your wrist.

### Part 5 — One-time watch convenience (optional)

Map the **Action button** (Ultra's orange button) to start dictation:

1. After the app is installed, open the **Shortcuts** app — the *"Speak a message
   in Pinch"* shortcut appears automatically.
2. On the watch: **Settings → Action Button → First Press → Shortcut**, pick it.
3. Press the orange button anytime → Pinch opens listening.

---

## Using it

| Action | Control |
|---|---|
| **Send** the message | Hardware **double-tap** (pinch), or tap Send on screen |
| **Talk** (dictate) | Tap the mic, or press the **Action button** |
| **Scroll** transcript | **Digital Crown** |
| **Move the text cursor** | Crown, inside the draft editor |
| **Delete previous word** | Swipe ← in the editor |
| **Approve / decline** an edit or command | Crown — **rotate** on the permission card (right = allow, left = deny); or tap ✓ / ✗ |
| **Pick mode / project** | Crown — rotate to highlight, **pause** to commit; or tap a row |
| **Cancel** the running turn | **Shake** your wrist |
| **Hear replies** | Automatic readback + haptic (wear AirPods to actually hear it) |

**Permission modes:** `default` (every mutation asks) · `acceptEdits` (edits
auto-approve, commands still ask) · `plan` (read-only) · `bypassPermissions`
(dangerously skip permissions — nothing asks; guarded confirm before you enter).

---

## Security — read this

This is **remote code execution as a service.** The bearer token is the only
thing between the public internet and an agent that can run `bash` in your repos.

- The repo is **public**. Secrets live in gitignored files only —
  `backend/.env` and `watch/Sources/Secrets.swift`. Never paste the token into
  committed source.
- Treat `PINCH_TOKEN` like an SSH key. If a device is lost or you see activity
  you didn't start, **rotate it and restart the backend** (a running process
  holds the old token until you bounce it).
- Run the backend as your normal, non-admin user.
- Full threat model, token rotation, and the incident kill-switch:
  **[`infra/SECURITY.md`](infra/SECURITY.md)**.

---

## Repo layout

| Path | What |
|---|---|
| `backend/` | Node/TypeScript service: Claude Agent SDK + HTTP/WS server. The brain. |
| `watch/` | watchOS SwiftUI app (generated by XcodeGen). The remote. |
| `packages/protocol/` | Shared wire protocol: Zod types + `PROTOCOL.md`. The contract. |
| `simulator/` | Browser "watch" — test end-to-end with no Apple hardware. |
| `infra/` | Tunnels (ngrok, cloudflared), launchers, launchd, cloud mode, token gen, `SECURITY.md`. |
| `docs/` | `PLAN.md`, `DECISIONS.md`, `SETUP.md`, `STATUS.md`. |
| `setup.sh` · `pinch-up.sh` | Bootstrap, and a foreground "build + run + tunnel" one-shot. |

---

## Known limits (watchOS realities, not bugs)

- **Double-tap is hardware-gated** to Series 9 / Ultra 2+. Everywhere else the
  on-screen Send button is the path; the app feature-detects and degrades.
- **TTS can be silent without AirPods.** watchOS often won't speak through the
  built-in speaker with no Bluetooth route, so every spoken reply is also a
  haptic. Wear AirPods to actually hear replies.
- **No background connection.** The app talks to the backend only while
  foreground; it reconnects and **resumes the session** (Claude keeps its
  context) when you reopen it. Prompts you send are held in a durable outbox and
  retried, so a message during an LTE handoff isn't lost.
- **Voice is Apple's system dictation,** not an always-on listener
  (`SFSpeechRecognizer` doesn't work on watchOS).
- **No crown press** for apps — "confirm/select" is built from crown *rotation*.
- **APNs push is stubbed.** The "long task finished, come look" notification
  needs an APNs key on your developer account to go live.

---

## Alternatives

- **Other tunnels.** `pinch-up.sh` also supports a named **Cloudflare Tunnel**
  (if you own a domain) and auto-detects what's configured. See
  `infra/cloudflared/README.md` and `infra/ngrok/README.md`.
- **Always-on cloud mode** (Fly.io). Runs without your Mac, but only sees
  **pushed** code and pushes its work back as a branch — it is *not* remote
  control of your Mac. See `infra/cloud/README.md`.
- **Persistence.** The Mac setup runs at the session level (survives logout, not
  a reboot). After a reboot, re-run `start-pinch.command` — the URL stays the
  same. There's a `launchd` path in `infra/launchd/`, with caveats documented
  there.

---

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Watch can't connect, simulator works locally | tunnel not running, or `PINCH_NGROK_DOMAIN` / `serverURL` mismatch |
| `unauthorized` on the watch | token in `Secrets.swift` ≠ `PINCH_TOKEN` in `backend/.env`, or you rotated the token and didn't restart the backend |
| Backend won't start | not built (`npm run build`), or `PINCH_PROJECT_ROOTS`/`PINCH_PROJECTS` unset in real mode |
| Agent "can't find" a repo | path not under `PINCH_PROJECT_ROOTS` / not in `PINCH_PROJECTS`, or not absolute |
| ngrok won't come up | not authed (`ngrok config add-authtoken …`), or the free single-session limit (kill the stale `ngrok` process) |
| Xcode signing fails | `DEVELOPMENT_TEAM` / bundle id in `project.yml` still point at the original author — set your own, then `xcodegen generate` |
| Changes don't take effect | rebuilding `dist/` isn't enough — **restart the backend**; watch changes need a fresh Xcode build + install |

Quick health check from the Mac: `curl localhost:8787/health`.
