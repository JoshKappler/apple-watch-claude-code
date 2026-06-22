# ngrok (fallback)

Use ngrok if you don't have a domain on Cloudflare, or you just want the
fastest possible "make localhost public" with zero config. ngrok fully supports
WebSockets. The tradeoff vs. Cloudflare Tunnel is the URL and the price:

- **Free plan:** one random `*.ngrok-free.app` URL that changes every restart
  (and a shared dev domain). Fine for a quick test; annoying for the watch
  because you'd re-enter the URL each time.
- **Paid (~$8/mo):** a **reserved** stable domain (e.g.
  `pinch.<you>.ngrok.app` or a custom domain) that survives restarts — the
  setup the watch wants.

## Install

```bash
brew install ngrok
ngrok config add-authtoken <YOUR_NGROK_AUTHTOKEN>   # from the ngrok dashboard
```

## Quick (free, ephemeral URL)

```bash
ngrok http 8787
# ngrok prints a line like:
#   Forwarding  https://1a2b-3c4d.ngrok-free.app -> http://localhost:8787
```

Your WebSocket endpoint is that host with the `/ws` path, over `wss://`:

```
wss://1a2b-3c4d.ngrok-free.app/ws
```

## Stable (paid reserved domain)

1. Reserve a domain in the ngrok dashboard (Domains → New Domain), e.g.
   `pinch.<you>.ngrok.app`.
2. Run:
   ```bash
   ngrok http --domain=pinch.<you>.ngrok.app 8787
   ```
3. Use the fixed endpoint in the watch/sim:
   ```
   wss://pinch.<you>.ngrok.app/ws
   ```

## Notes

- Auth is still `PINCH_TOKEN` over the WS handshake (Authorization: Bearer or
  first frame). ngrok is just transport — see `infra/SECURITY.md`.
- ngrok's edge keeps WS open longer than Cloudflare's 100s idle window, but the
  app's 25s heartbeat applies regardless, so behavior is the same.
- For always-on operation, run ngrok under launchd similarly to the tunnel
  (swap the ProgramArguments in a copy of `com.pinch.tunnel.plist` for
  `ngrok http --domain=... 8787`). Cloudflare Tunnel is still the recommended
  default.
