# infra/ — deploy & reach Pinch from your watch

The backend is a Node server on `localhost:8787`: a WebSocket at `/ws` (browser
simulator), an HTTP API at `/api/*` (the watch — watchOS refuses WebSockets on
its network path), and `/health`. Auth on every path is a bearer `PINCH_TOKEN`.
This directory is everything needed to make that reachable from an Apple Watch
over **cellular** (a public URL), securely, and to keep it running.

> This is RCE-as-a-service. Read **[SECURITY.md](./SECURITY.md)** before exposing
> anything publicly.

## Deployment modes

| Mode | What | Where to look |
|---|---|---|
| **Mac + ngrok** (recommended) | A reserved **free static domain** gives your Mac a stable URL that never changes. Free, no domain of your own needed. The agent edits your real local repos. | [`ngrok/`](./ngrok/) |
| **Mac + Cloudflare Tunnel** | A named `cloudflared` tunnel on your own domain. Free, stable hostname, no inbound ports — if you already own a domain on Cloudflare. | [`cloudflared/`](./cloudflared/) |
| **Cloud (Fly.io)** | Always-on Machine, no Mac needed. Clones repos from GitHub at boot; only sees **pushed** code. | [`cloud/`](./cloud/) |

### Decision table

| | Cost | Always-on | Sees uncommitted local changes | Setup |
|---|---|---|---|---|
| **Mac + ngrok** | Free | Only while Mac awake | **Yes** (real working tree) | Low — reserve one free domain |
| **Mac + Cloudflare Tunnel** | Free | Only while Mac awake | **Yes** | Medium — needs your own domain |
| **Cloud (Fly.io)** | ~$2–20/mo | **Yes** | No — pushed code only | Medium-high |

**Recommended: Mac + ngrok.** Free, the static domain never changes (so the URL
baked into the watch keeps working across restarts), and the agent edits your
*real* repos in place. The catch: your Mac has to be awake. If you own a domain
and prefer Cloudflare, that path is fully scaffolded. If you need always-on and
can live with pushed-code-only, go cloud.

## Bringing it up

```bash
npm run build                 # build the backend from dist/ (npm run up does NOT build)
npm run up                    # install + start the always-on launchd service
```

`npm run up` installs three LaunchAgents (`com.pinch.server`, `com.pinch.tunnel`,
`com.pinch.watchdog`) and loads them. The backend runs on `:8787` and the tunnel
on your `PINCH_NGROK_DOMAIN`. They start at login, restart on crash, and the
watchdog re-kicks anything wedged/booted-out every 120s — always-on. `npm run
down` stops and removes it.

## Contents

```
infra/
├── README.md                  ← you are here
├── SECURITY.md                ← token model, rotation, kill-switch (read this)
├── start-tunnel.sh            ← run a named Cloudflare Tunnel in the foreground
├── ngrok/
│   └── README.md              ← the recommended path: free static domain + PINCH_NGROK_DOMAIN
├── cloudflared/
│   ├── config.example.yml     ← ingress: agent.<yourdomain> → http://localhost:8787 + 404 catch-all
│   ├── setup-named-tunnel.sh  ← one-time named-tunnel setup
│   └── README.md              ← named-tunnel walkthrough (scaffolded; unused unless you own a domain)
├── launchd/                       ← always-on: start at login, restart on crash, watchdog
│   ├── com.pinch.server.plist     ← keep the backend alive (restart on crash)
│   ├── com.pinch.tunnel.plist     ← keep a cloudflared tunnel alive
│   ├── com.pinch.tunnel.ngrok.plist ← keep an ngrok tunnel alive (recommended path)
│   ├── com.pinch.watchdog.plist   ← every 120s, re-kick anything wedged/booted-out
│   ├── pinch-watchdog.mjs         ← the health check the watchdog agent runs (node)
│   ├── install-launchd.sh         ← `npm run up`: substitute paths, load into ~/Library/LaunchAgents
│   └── uninstall-launchd.sh       ← `npm run down`: bootout + remove
├── scripts/
│   ├── gen-token.mjs          ← print a fresh base64url PINCH_TOKEN
│   └── gen-token.sh           ← wrapper
└── cloud/
    ├── Dockerfile             ← Node 20 image; build from repo root
    ├── fly.toml               ← always-on Machine + volume
    ├── entrypoint.sh          ← clone repos from $REPOS, run the server
    └── README.md              ← cloud walkthrough + "pushed code only" tradeoff
```

## Notes

- **`npm run up` is true always-on.** It installs three LaunchAgents
  (`com.pinch.server` + `com.pinch.tunnel` + `com.pinch.watchdog`) that start at
  login, restart on crash (`KeepAlive` on non-clean exit, throttled 10s), and come
  back after a reboot. The watchdog re-kicks or re-bootstraps anything wedged or
  booted-out every 120s — the case `KeepAlive` alone can't catch (alive but
  wedged). Build first (`npm run build`); the installer does not build. The
  installer auto-detects the tunnel: a `~/.cloudflared/config.yml` → cloudflared,
  else `PINCH_NGROK_DOMAIN` in `backend/.env` → ngrok. Force it with `TUNNEL=ngrok`
  or `TUNNEL=cloudflared`. The reserved domain keeps the watch URL stable across
  every restart, so the watch never needs reconfiguring. Manage it with:
    ```
    launchctl print gui/$(id -u)/com.pinch.server | head -20   # status
    launchctl kickstart -k gui/$(id -u)/com.pinch.server       # reload new build
    npm run down                                                # stop + remove
    ```
  Reloading after a code change: rebuild (`npm run build --workspace backend`)
  then `kickstart -k` the server. The watch's own `POST /api/restart` already
  does this when the agents are installed.
- **First install may prompt for permissions (TCC).** launchd starting `node`/the
  tunnel can trigger a one-time macOS permission prompt; approve it.
- **Idle WebSocket timeout** only affects the simulator's `/ws` path (Cloudflare
  closes idle sockets after ~100s; the app sends a 25s heartbeat). The watch uses
  short HTTP requests, so it isn't subject to a socket idle timeout.

Full end-to-end walkthrough: **[`../docs/SETUP.md`](../docs/SETUP.md)**. Or run
**`./setup.sh`** from the repo root to bootstrap.
