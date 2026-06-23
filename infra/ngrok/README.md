# ngrok — the recommended transport

ngrok gives your Mac's backend a public URL the watch can reach over cellular,
with **zero domain of your own**. Crucially, ngrok's free tier now includes one
**reserved static domain** — a permanent URL that survives restarts. That's what
makes it the recommended path: the URL baked into the watch build keeps working,
so a backend restart (or reboot) never strands the watch.

```
watch  ⇄  https://<your-domain>.ngrok-free.dev  ⇄  ngrok agent  ⇄  http://localhost:8787
```

> The watch transport is **HTTP** (`/api/*` + a poll loop) — watchOS refuses
> WebSockets on the watch's network path. The browser simulator uses `/ws`. ngrok
> carries both; it's just transport.

## Install + authenticate (one-time)

```bash
brew install ngrok
ngrok config add-authtoken <YOUR_NGROK_AUTHTOKEN>   # from the ngrok dashboard
```

## Reserve your free static domain (one-time)

In the ngrok dashboard: **Domains → New Domain** → reserve a free static domain
(e.g. `your-name-here.ngrok-free.dev`). Put it in `backend/.env`:

```ini
PINCH_NGROK_DOMAIN=your-name-here.ngrok-free.dev
```

ngrok free allows **one agent session at a time**, which is all Pinch needs.

## Run it

The always-on service does everything (backend + ngrok on the static domain,
start at login, restart on crash, watchdog-monitored):

```bash
npm run build
npm run up                       # install + start the launchd service
```

Or by hand:

```bash
ngrok http 8787 --url=https://your-name-here.ngrok-free.dev
```

Your endpoint is the static host. Enter it in the watch's `Secrets.swift` /
Settings as `wss://your-name-here.ngrok-free.dev` (the app normalizes it to HTTPS
for the watch's HTTP transport). The simulator uses
`wss://your-name-here.ngrok-free.dev/ws`.

## Notes

- Auth is `PINCH_TOKEN` on every request (`Authorization: Bearer`). ngrok is just
  transport — see `infra/SECURITY.md`.
- The watch sends `ngrok-skip-browser-warning` on every request to bypass the
  free-tier interstitial. (Already wired in the app.)
- If ngrok didn't come up: check you're authed (`ngrok config add-authtoken …`)
  and that no stale `ngrok` process holds the single free session (`pkill -f
  'ngrok http'`). Logs: `/tmp/pinch-ngrok.log`.
- **No reserved domain?** A bare `ngrok http 8787` still works for a quick test,
  but the URL changes every run, so you'd re-enter it on the watch each time —
  reserve the free static domain instead.
- **Want it to survive logout/crash/reboot?** That's the default: `npm run up`
  installs an always-on launchd service that runs ngrok on `$PINCH_NGROK_DOMAIN`,
  restarts on crash, and is watchdog-monitored. See `infra/launchd/`.
