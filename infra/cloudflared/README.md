# Cloudflare Tunnel (if you own a domain)

A **named** Cloudflare Tunnel gives Pinch a stable public hostname on **your own
domain**, with TLS terminated at Cloudflare's edge. Free, your own hostname, no
inbound ports opened on your Mac. Use this if you already have a domain on
Cloudflare; if you don't, the **ngrok free static domain** ([`../ngrok/`](../ngrok/))
is the recommended no-domain default. `npm run up` auto-detects a `~/.cloudflared/
config.yml` and prefers it when present (force with `TUNNEL=cloudflared`).

```
Watch (HTTP /api) / Simulator (/ws) ⇄ agent.<yourdomain> ⇄ Cloudflare edge ⇄ cloudflared ⇄ http://localhost:8787
```

## Prerequisites

- A domain on a Cloudflare account (free plan is fine). The domain's
  nameservers must point at Cloudflare.
- `cloudflared` installed:
  ```bash
  brew install cloudflared
  ```

## One-time setup

Run these once. They write credentials into `~/.cloudflared/`.

```bash
# 1. Authenticate cloudflared with your Cloudflare account (opens a browser).
#    Writes ~/.cloudflared/cert.pem
cloudflared tunnel login

# 2. Create the named tunnel. Prints the TUNNEL-UUID and writes
#    ~/.cloudflared/<TUNNEL-UUID>.json (the credentials file).
cloudflared tunnel create pinch

# 3. Route a DNS hostname to the tunnel. Creates a proxied CNAME at Cloudflare.
#    Replace <yourdomain> with your actual domain.
cloudflared tunnel route dns pinch agent.<yourdomain>
```

Then install the ingress config:

```bash
cp "infra/cloudflared/config.example.yml" ~/.cloudflared/config.yml
# Edit ~/.cloudflared/config.yml:
#   - replace TUNNEL-UUID (both the `tunnel:` value and the credentials path)
#   - replace agent.<yourdomain> with your hostname
```

Find your tunnel's UUID at any time:

```bash
cloudflared tunnel list
```

## Run it

```bash
infra/start-tunnel.sh
# (equivalent to: cloudflared tunnel --config ~/.cloudflared/config.yml run pinch)
```

To keep it running across reboots/crashes, use the launchd agent instead — see
`infra/launchd/`.

## The URL for the watch / simulator

Your public host is `agent.<yourdomain>`. Enter it with the `PINCH_TOKEN` bearer:

- **Watch** (`Secrets.swift` / Settings): `wss://agent.<yourdomain>` — the app
  normalizes it and uses the HTTP `/api/*` paths under the hood.
- **Simulator** (connection field): `wss://agent.<yourdomain>/ws`.

The token goes in the `Authorization: Bearer <token>` header (or the simulator's
first `auth` frame) — **never** in the query string.

## Idle-timeout gotcha (100s)

Cloudflare's edge closes **idle** WebSocket connections after ~**100 seconds**.
Pinch already sends a **25s heartbeat** from both client and server, so an open
session never goes idle long enough to be cut. You do not need to configure
anything — just know that if you ever disable the heartbeat, long pauses (e.g.
the agent thinking quietly) would drop the socket. The `originRequest` keepalive
settings in `config.example.yml` keep the origin side patient too.

## Optional: Cloudflare Access in front (defense in depth)

You can require a Cloudflare **service token** (or mTLS) so unauthenticated
traffic never even reaches Node. Add a self-hosted Access application for
`agent.<yourdomain>` and a Service Auth policy, then have the watch/sim send the
`CF-Access-Client-Id` / `CF-Access-Client-Secret` headers. This is layered on
*top* of `PINCH_TOKEN`, not a replacement for it. See `infra/SECURITY.md`.
