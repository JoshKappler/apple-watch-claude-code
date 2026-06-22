# Pinch setup — from zero to talking to your repo from your watch

This stitches the backend + a public tunnel + the watch/simulator into one
working flow. By the end you'll send a message from a client over a public
`wss://` URL and watch a Claude agent edit your repo.

Pick **one** transport. The recommended path is **Mac + Cloudflare Tunnel**
(free, stable hostname, agent sees your real local repos). Alternatives: ngrok
(quick, fallback) or Fly.io cloud (always-on, no Mac, but only sees pushed code).

```
Watch / Simulator  ⇄  wss://agent.<yourdomain>/ws  ⇄  Cloudflare edge  ⇄  cloudflared  ⇄  backend :8787  ⇄  your repos
```

> Read **[`../infra/SECURITY.md`](../infra/SECURITY.md)** first. This exposes a
> coding agent that can run Bash and edit files. The token is the only lock.

---

## Secrets you'll need

| Secret | Where it goes | What it is |
|---|---|---|
| `PINCH_TOKEN` | `backend/.env` **and** the watch/sim | Device bearer token. Generate it; same value on both ends. |
| `ANTHROPIC_API_KEY` | `backend/.env` | Anthropic key for the Agent SDK. Not needed if `PINCH_MOCK=1`. |
| `PINCH_PROJECTS` | `backend/.env` | Comma-separated **absolute** repo paths the agent may edit (allowlist). |
| `GITHUB_TOKEN` | Fly secrets (cloud mode only) | Clones/pushes repos in the cloud. |

---

## Order of operations (Mac + Cloudflare Tunnel)

### 0. Bootstrap (optional but easy)

From the repo root:

```bash
./setup.sh
```

It checks `node`/`cloudflared`, creates `backend/.env` from the example (without
overwriting an existing one), and generates a `PINCH_TOKEN`. Then continue at
step 2 (fill in the remaining `.env` values). To do it by hand, start at step 1.

### 1. Backend env + token

```bash
cd backend
cp .env.example .env          # skip if setup.sh already did it
# Generate a device token and drop it in:
node ../infra/scripts/gen-token.mjs        # prints the token + a paste-in line
```

Edit `backend/.env`:

```ini
ANTHROPIC_API_KEY=sk-ant-...                 # or leave blank and set PINCH_MOCK=1
PINCH_TOKEN=<the token you just generated>
PORT=8787
PINCH_PROJECTS=/Users/josh/desktop/apple watch   # absolute path(s), comma-separated
PINCH_MOCK=0
PINCH_MODEL=claude-opus-4-8
LOG_LEVEL=info
```

> `PINCH_PROJECTS` is the agent's allowlist — it can only touch repos under
> these absolute roots. Paths may contain spaces; no quotes needed in `.env`.

### 2. Install and run the backend

From the repo root:

```bash
npm install
npm run dev            # tsx watch — backend on ws://localhost:8787/ws
```

Leave it running. (For production/always-on, `npm run build --workspace backend`
then use the launchd agent in step 5.)

### 3. Smoke-test locally with the simulator

In a second terminal, from the repo root:

```bash
npm run sim            # Vite dev server, opens the browser "watch" (default :5173)
```

In the simulator's connection settings, point it at the **local** server first
to confirm the backend works before going public:

```
URL:   ws://localhost:8787/ws
Token: <PINCH_TOKEN>
```

Send a message; you should see the agent respond and (if not in mock mode) start
using tools. If this works, the transport is the only thing left.

### 4. Create the Cloudflare Tunnel (one-time)

Requires a domain on your Cloudflare account and `cloudflared`
(`brew install cloudflared`).

```bash
cloudflared tunnel login                          # browser auth
cloudflared tunnel create pinch                   # prints TUNNEL-UUID, writes ~/.cloudflared/<UUID>.json
cloudflared tunnel route dns pinch agent.<yourdomain>
```

Install the ingress config:

```bash
cp "infra/cloudflared/config.example.yml" ~/.cloudflared/config.yml
# Edit ~/.cloudflared/config.yml:
#   tunnel:           <TUNNEL-UUID>
#   credentials-file: /Users/josh/.cloudflared/<TUNNEL-UUID>.json
#   ingress hostname: agent.<yourdomain>
```

Details + how to find the UUID later: `infra/cloudflared/README.md`.

### 5. Run the tunnel

Foreground (quick test):

```bash
infra/start-tunnel.sh
```

Always-on (survives logout/crash/reboot) — install the launchd agents:

```bash
# Builds first if you haven't: npm run build --workspace backend
infra/launchd/install-launchd.sh
# Status:  launchctl print gui/$(id -u)/com.pinch.server | head
# Logs:    ~/Library/Logs/pinch/{server,tunnel}.{out,err}.log
# Remove:  infra/launchd/uninstall-launchd.sh
```

The launchd server agent runs `node dist/index.js` from `backend/`, so build the
backend before relying on it.

### 6. Connect a client over cellular

Your public endpoint is:

```
wss://agent.<yourdomain>/ws
```

- **Simulator:** put that URL + the `PINCH_TOKEN` in the connection settings.
- **Watch app:** enter the same URL and token in its settings screen. With the
  watch on cellular (Wi-Fi off, away from your Mac's network), send a message
  with the double-tap pinch — you're now driving the agent on your Mac from your
  wrist.

The token goes in the `Authorization: Bearer` header or the first frame, never
the query string.

> **100s idle note:** Cloudflare drops idle WebSockets after ~100s. The app
> sends a 25s heartbeat on both ends, so live sessions stay up. Nothing to do.

---

## Alternative transports

- **ngrok (fallback):** `infra/ngrok/README.md`. `ngrok http 8787` for a quick
  random URL, or a reserved domain (~$8/mo) for a stable one. Same `PINCH_TOKEN`.
- **Fly.io cloud (always-on, no Mac):** `infra/cloud/README.md`. Clones your
  GitHub repos at boot; the agent only sees **pushed** code, and pushes its work
  back as a branch/PR. Set `ANTHROPIC_API_KEY`, `PINCH_TOKEN`, `GITHUB_TOKEN`,
  and `REPOS` via `fly secrets`. Not Vercel — serverless can't hold a WebSocket.

---

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Client connects locally but not via tunnel | tunnel not running, wrong hostname in config, or DNS route not created |
| Connection drops after ~100s | heartbeat disabled; Cloudflare closed the idle socket |
| Auth rejected | token mismatch between `backend/.env` and the client, or sent in the query string |
| Agent "can't find/edit" a repo | path not in `PINCH_PROJECTS`, or not an absolute path |
| launchd agent won't stay up | `dist/index.js` not built, or wrong `NODE_BIN`; check `~/Library/Logs/pinch/server.err.log` |

Rotation and the incident kill-switch: **[`../infra/SECURITY.md`](../infra/SECURITY.md)**.
