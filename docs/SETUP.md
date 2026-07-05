# Pinch setup — from zero to talking to your repo from your watch

This is the long-form walkthrough. The top-level [`README.md`](../README.md) is the
fast path; this doc adds detail, alternatives, and troubleshooting. By the end
you'll send a voice message from your watch over a public URL and watch a Claude
agent edit your repo.

The recommended transport is a **stable ngrok free static domain** — free, no
domain of your own required, and the URL never changes (so the build baked into
the watch keeps working across restarts). Alternatives (a named Cloudflare
Tunnel, Fly.io cloud) are at the bottom.

```
Apple Watch  ⇄  HTTPS + ~1.2s poll  ⇄  ngrok edge  ⇄  ngrok agent  ⇄  backend :8787  ⇄  your repos
```

> The watch talks to the backend over **HTTP** (`/api/*`), not WebSockets —
> watchOS refuses `URLSessionWebSocketTask` on the watch's network path. The
> browser **simulator** uses the WebSocket (`/ws`) path. Same sessions, two
> transports.

> Read **[`../infra/SECURITY.md`](../infra/SECURITY.md)** first. This exposes a
> coding agent that can run Bash and edit files. The token is the only lock.

---

## Secrets you'll need

| Secret | Where it goes | What it is |
|---|---|---|
| `PINCH_TOKEN` | `backend/.env` **and** the watch (`Secrets.swift`) | Device bearer token. Generated for you by `setup.sh`; same value on both ends. |
| `PINCH_AUTH` | `backend/.env` | `subscription` (default — uses your Mac's Claude Code login, no key) or `apikey`. |
| `ANTHROPIC_API_KEY` | `backend/.env` | Only when `PINCH_AUTH=apikey`. Not needed in subscription or mock mode. |
| `PINCH_PROJECT_ROOTS` | `backend/.env` | Parent dir(s) to scan — every child repo becomes a selectable project. |
| `PINCH_NGROK_DOMAIN` | `backend/.env` | Your reserved ngrok free static domain (read by `npm run up`). |

---

## Order of operations (Mac + ngrok)

### 0. Bootstrap

From the repo root:

```bash
./setup.sh
```

It checks `node`, creates `backend/.env` from the example (without overwriting an
existing one), generates a `PINCH_TOKEN`, and creates
`watch/Sources/Shared/Secrets.swift` (gitignored) with the token filled in. Then edit
`backend/.env` to fill in the rest.

### 1. Backend env

Edit `backend/.env`:

```ini
# subscription = use the Mac's Claude Code login (Claude Max/Pro). No key. Default.
# apikey       = use ANTHROPIC_API_KEY instead.
PINCH_AUTH=subscription
ANTHROPIC_API_KEY=

PINCH_TOKEN=<filled in by setup.sh>

# Point this at a PARENT folder. Every child repo shows up on the watch,
# recency-sorted, recomputed each time you open the picker (clone a repo and it
# just appears — no restart). The agent cds into whichever you pick.
PINCH_PROJECT_ROOTS=/Users/you/Desktop/projects
# Optional: explicit absolute repo paths to also allow.
PINCH_PROJECTS=

PORT=8787
PINCH_MODEL=claude-opus-4-8

# Your reserved ngrok free static domain (step 3).
PINCH_NGROK_DOMAIN=your-name-here.ngrok-free.dev
```

> If `PINCH_AUTH=subscription`, run `claude` once in a terminal and finish the
> login. The backend reuses that keychain session — no API key. The config layer
> scrubs any stray/empty `ANTHROPIC_API_KEY` so it can't override the login.

> `PINCH_PROJECT_ROOTS` / `PINCH_PROJECTS` is the agent's allowlist — it can only
> touch repos under these roots. Paths may contain spaces; no quotes in `.env`.

### 2. Install and smoke-test without a watch

```bash
npm install

# terminal 1 — backend in mock mode (scripted agent, no SDK, no key)
PINCH_MOCK=1 PINCH_TOKEN=dev-token npm run dev

# terminal 2 — the browser "watch"
npm run sim
```

In the simulator, connect to `ws://localhost:8787/ws` with token `dev-token`,
send a prompt, and watch the scripted turn stream in — including the permission
card you approve with a click. When that works, drop `PINCH_MOCK`, set
`PINCH_PROJECT_ROOTS`, and you have a real agent on your repos locally.

> The simulator uses the WebSocket path; the watch uses HTTP. Both exercise the
> same backend session logic, so a green simulator means the brain works.

### 3. Reserve a stable ngrok domain (one-time)

```bash
brew install ngrok
ngrok config add-authtoken <token-from-the-ngrok-dashboard>
```

In the ngrok dashboard: **Domains → New Domain** → reserve a free static domain
(e.g. `your-name-here.ngrok-free.dev`). Put it in `backend/.env` as
`PINCH_NGROK_DOMAIN`. It's free, permanent, and yours. ngrok free allows one
agent session at a time, which is all you need.

### 4. Build the backend and bring the tether up

```bash
npm run build                 # build the backend (npm run up does NOT build)
npm run up                    # install + start the always-on launchd service
```

`npm run up` installs three LaunchAgents (`com.pinch.server`, `com.pinch.tunnel`,
`com.pinch.watchdog`) on `:8787` + your static ngrok domain. They start at login,
restart on crash, and a watchdog re-kicks anything wedged/booted-out every 120s —
always-on. The installer reads `PINCH_NGROK_DOMAIN` from `backend/.env` to keep
the URL fixed. It auto-detects the tunnel (`~/.cloudflared/config.yml` →
cloudflared, else ngrok; force with `TUNNEL=ngrok` / `TUNNEL=cloudflared`).
`npm run down` stops and removes it.

### 5. The watch app

You'll need **Xcode 16+** and **XcodeGen** (`brew install xcodegen`) — the Xcode
project is generated from `watch/project.yml` (it's gitignored, not committed).
The committed `project.yml` has the original author's Apple Team baked in, so
**change it to yours before generating** or signing fails.

```yaml
# watch/project.yml
options:
  bundleIdPrefix: com.yourname.pinch        # a prefix you own
targets:
  Pinch:
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.yourname.pinch.watch
        DEVELOPMENT_TEAM: XXXXXXXXXX         # your Apple Team ID
```

Then:

```bash
cd watch
xcodegen generate            # reads project.yml → writes Pinch.xcodeproj
open Pinch.xcodeproj
```

Set `watch/Sources/Shared/Secrets.swift` (created by `setup.sh`, gitignored — never
commit it):

```swift
enum Secrets {
    static let serverURL = "wss://your-name-here.ngrok-free.dev"  // your ngrok domain
    static let token = "<your PINCH_TOKEN>"                       // already filled in
}
```

Enter the `wss://` URL — the app normalizes it and uses HTTPS for the HTTP
transport under the hood. This is the build-time default; you can also type/override
it in the watch's Settings screen, and that override persists.

Pick your watch as the run destination and **Run**. The first on-device install
needs you to trust your developer certificate (Watch app → General → VPN & Device
Management). Details and the control map: [`../watch/README.md`](../watch/README.md).

### 6. Use it over cellular

Open the app, take your phone out of range (or turn Wi-Fi off to prove cellular),
and send a message with the double-tap pinch. You're driving an agent on your Mac
from your wrist. Because the ngrok domain is stable, you only ever re-enter the
URL if you reset the watch's settings.

The token goes in the `Authorization: Bearer` header on every request, never the
query string.

---

## Alternative transports

- **Named Cloudflare Tunnel (own domain, stable):** if you have a domain on
  Cloudflare, `cloudflared tunnel login/create/route`, then
  `cp infra/cloudflared/config.example.yml ~/.cloudflared/config.yml` and fill in
  the UUID + hostname. `npm run up` auto-detects the config and uses it (force
  with `TUNNEL=cloudflared`). Full steps: `infra/cloudflared/README.md`.
- **Fly.io cloud (always-on, no Mac):** `infra/cloud/README.md`. Clones your
  GitHub repos at boot; the agent only sees **pushed** code and pushes its work
  back as a branch. It is *not* remote control of your Mac. Not Vercel —
  serverless can't hold a long-lived agent session.

---

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Watch can't connect, simulator works locally | tunnel not running, or `PINCH_NGROK_DOMAIN` ≠ `serverURL` in `Secrets.swift` |
| `unauthorized` on the watch | token in `Secrets.swift` ≠ `PINCH_TOKEN` in `backend/.env`, or you rotated the token and didn't restart the backend |
| Backend won't start | not built (`npm run build`), or `PINCH_PROJECT_ROOTS`/`PINCH_PROJECTS` unset in real mode |
| Agent "can't find/edit" a repo | path not under a configured root, or not absolute |
| ngrok won't come up | not authed (`ngrok config add-authtoken …`), or the free single-session limit — kill the stale `ngrok` process |
| Xcode signing fails | `DEVELOPMENT_TEAM` / bundle id in `project.yml` still point at the original author |
| Changes don't take effect | rebuilding `dist/` isn't enough — **restart the backend**; watch changes need a fresh Xcode build + install |

Health check from the Mac: `curl localhost:8787/health`. Rotation and the
incident kill-switch: **[`../infra/SECURITY.md`](../infra/SECURITY.md)**.
