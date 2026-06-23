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
npm run build                 # the launcher runs the backend from dist/
infra/start-pinch.command     # double-click in Finder, or run it
```

`start-pinch.command` is idempotent + detached (`nohup`): it reuses a healthy
backend on `:8787` and a live ngrok tunnel on your `PINCH_NGROK_DOMAIN`, starts
only what's missing, and prints the URL + token. Close the window and walk away —
it serves while the Mac is logged in and awake.

For a foreground "build + run + tunnel" one-shot that tears everything down on
Ctrl-C (and auto-detects a Cloudflare config → ngrok → LAN-only), use
[`../pinch-up.sh`](../pinch-up.sh).

## Contents

```
infra/
├── README.md                  ← you are here
├── SECURITY.md                ← token model, rotation, kill-switch (read this)
├── start-pinch.command        ← double-click launcher: backend + stable ngrok tunnel (nohup)
├── start-tunnel.sh            ← run a named Cloudflare Tunnel in the foreground
├── ngrok/
│   └── README.md              ← the recommended path: free static domain + PINCH_NGROK_DOMAIN
├── cloudflared/
│   ├── config.example.yml     ← ingress: agent.<yourdomain> → http://localhost:8787 + 404 catch-all
│   ├── setup-named-tunnel.sh  ← one-time named-tunnel setup
│   └── README.md              ← named-tunnel walkthrough (scaffolded; unused unless you own a domain)
├── launchd/
│   ├── com.pinch.server.plist ← keep the backend alive (restart on crash)
│   ├── com.pinch.tunnel.plist ← keep the tunnel alive
│   ├── install-launchd.sh     ← substitute paths, bootstrap into ~/Library/LaunchAgents
│   └── uninstall-launchd.sh   ← bootout + remove
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

- **Persistence is session-level.** The backend + tunnel run under `nohup` —
  they survive logout but not a reboot. After a reboot, re-run
  `start-pinch.command` (the URL stays the same). The `launchd/` agents are an
  alternative, with a TCC caveat documented there.
- **Idle WebSocket timeout** only affects the simulator's `/ws` path (Cloudflare
  closes idle sockets after ~100s; the app sends a 25s heartbeat). The watch uses
  short HTTP requests, so it isn't subject to a socket idle timeout.

Full end-to-end walkthrough: **[`../docs/SETUP.md`](../docs/SETUP.md)**. Or run
**`./setup.sh`** from the repo root to bootstrap.
