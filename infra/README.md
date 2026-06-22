# infra/ — deploy & reach Pinch from your watch

The backend is a Node WebSocket server on `localhost:8787`, path `/ws`,
authenticated by a bearer `PINCH_TOKEN`. This directory is everything needed to
make that reachable from an Apple Watch over **cellular** (a public `wss://`
URL), securely, and to keep it running.

> This is RCE-as-a-service. Read **[SECURITY.md](./SECURITY.md)** before exposing
> anything publicly.

## Three deployment modes

| Mode | What | Where to look |
|---|---|---|
| **Mac + Cloudflare Tunnel** (recommended) | A named `cloudflared` tunnel gives your Mac a stable `wss://agent.<yourdomain>/ws`. Free, your own hostname, no inbound ports. | [`cloudflared/`](./cloudflared/) |
| **Mac + ngrok** (fallback) | Zero-config public URL. Free = random URL; ~$8/mo = stable reserved domain. | [`ngrok/`](./ngrok/) |
| **Cloud (Fly.io)** | Always-on Machine, no Mac needed. Clones repos from GitHub at boot; only sees **pushed** code. | [`cloud/`](./cloud/) |

### Decision table

| | Cost | Always-on | Sees uncommitted local changes | Setup effort |
|---|---|---|---|---|
| **Mac + Cloudflare Tunnel** | Free | Only while Mac awake | **Yes** (real working tree) | Medium (one-time domain + tunnel) |
| **Mac + ngrok** | Free / ~$8/mo for stable URL | Only while Mac awake | **Yes** | Low |
| **Cloud (Fly.io)** | ~$2–20/mo | **Yes** | No — pushed code only | Medium-high |

**Recommended: Mac + Cloudflare Tunnel.** It's free, gives you a stable
hostname, and the agent edits your *real* repos in place (uncommitted changes and
all). The only catch: your Mac has to be awake. If you need always-on and can
live with the agent seeing only pushed code, go cloud.

> **Idle-WS gotcha (Cloudflare):** the edge closes idle WebSockets after ~100s.
> The app sends a **25s heartbeat** on both ends, so live sessions never trip it.
> Nothing to configure — just don't disable the heartbeat. (See
> `cloudflared/README.md`.)

## Contents

```
infra/
├── README.md                  ← you are here
├── SECURITY.md                ← token model, rotation, kill-switch (read this)
├── start-tunnel.sh            ← run the named Cloudflare Tunnel in the foreground
├── cloudflared/
│   ├── config.example.yml     ← ingress: agent.<yourdomain> → ws://localhost:8787 + 404 catch-all
│   └── README.md              ← one-time setup, the wss:// URL, idle note, Access
├── launchd/
│   ├── com.pinch.server.plist ← keep the backend alive (restart on crash)
│   ├── com.pinch.tunnel.plist ← keep the tunnel alive
│   ├── install-launchd.sh     ← substitute paths, bootstrap into ~/Library/LaunchAgents
│   └── uninstall-launchd.sh   ← bootout + remove
├── scripts/
│   ├── gen-token.mjs          ← print a fresh base64url PINCH_TOKEN
│   └── gen-token.sh           ← wrapper
├── ngrok/
│   └── README.md              ← fallback transport
└── cloud/
    ├── Dockerfile             ← Node 20 image; build from repo root
    ├── fly.toml               ← always-on Machine + volume + WS service
    ├── entrypoint.sh          ← clone repos from $REPOS, run the server
    └── README.md              ← cloud walkthrough + "pushed code only" tradeoff
```

## Fastest path (Mac + Cloudflare Tunnel)

1. `node infra/scripts/gen-token.mjs` → put `PINCH_TOKEN` in `backend/.env`.
2. Build + run the backend (`npm run build --workspace backend && npm run dev`).
3. One-time tunnel setup (`cloudflared login` / `create pinch` / `route dns`),
   then `cp infra/cloudflared/config.example.yml ~/.cloudflared/config.yml` and
   fill in the UUID + hostname.
4. `infra/start-tunnel.sh` (or install the launchd agents to keep it up).
5. In the watch/sim, set the URL to `wss://agent.<yourdomain>/ws` and the same
   token.

Full end-to-end walkthrough: **[`../docs/SETUP.md`](../docs/SETUP.md)**. Or just
run **`./setup.sh`** from the repo root to bootstrap.
