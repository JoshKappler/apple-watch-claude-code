# Pinch security

Be honest about what this is: **remote code execution as a service.** Anyone who
can open the WebSocket and present a valid token can make a Claude agent run
Bash, edit files, and (in "dangerously skip permissions" mode) act with full
autonomy inside your repos and on the host. Treat the device token like the root
password it effectively is.

## Threat model

- The transport is public (cellular → Cloudflare/Fly → your origin). Assume the
  URL will be discovered.
- The only thing standing between the internet and a shell is the **token check
  on the handshake** (plus any optional Cloudflare Access layer).
- A leaked token = full compromise of whatever the backend can reach.

## Layered auth (defense in depth)

1. **TLS only.** The edge (Cloudflare / Fly) terminates TLS; the origin is
   `localhost`/internal. The watch and sim always connect with `wss://`, never
   `ws://`. No plaintext on the wire.
2. **Device token (`PINCH_TOKEN`).** 32 random bytes, base64url
   (`crypto.randomBytes(32).toString('base64url')`). Generate with
   `infra/scripts/gen-token.mjs`. Sent in the **`Authorization: Bearer` header
   or the first frame — never the query string** (query strings leak into
   proxy/edge logs, browser history, and Referer headers). The backend validates
   it **constant-time** on the handshake and drops the socket on mismatch before
   any agent work begins.
3. **Path allowlist.** The server only accepts the `/ws` path; everything else
   is rejected (and the Cloudflare ingress 404s non-matching hosts/paths before
   they reach Node). The agent is also constrained to `PINCH_PROJECTS` repo
   roots — paths outside the allowlist are refused.
4. **Optional Cloudflare Access (service token / mTLS).** Put an Access policy in
   front of `agent.<yourdomain>` so unauthenticated requests never reach Node at
   all. The watch/sim then also send `CF-Access-Client-Id` /
   `CF-Access-Client-Secret`. This is *in addition to* `PINCH_TOKEN`.
5. **Rate limiting.** The backend rate-limits handshakes/messages to blunt
   brute-force and abuse.
6. **Least privilege.** Run the backend as a **regular, non-admin** user (the
   launchd agents run in the per-user `gui/$(id -u)` domain, never as root). In
   cloud mode, scope `GITHUB_TOKEN` to only the repos in `REPOS` with the minimum
   permissions.

## Secret hygiene

- Secrets live in `backend/.env` (Mac) or `fly secrets` (cloud) — **never** in
  plists, fly.toml, git, or the tunnel config. `.env`, `*.pem`, `*.key`, and
  `*.cloudflared.json` are gitignored; keep `backend/.env` at `chmod 600`.
- The token is the same string on both ends (backend + watch/sim). Rotating it
  means updating both.

## Token rotation / revocation

The token is "revocable" by replacing it — there is exactly one valid value at a
time, so changing it instantly invalidates every client that hasn't been
updated.

Rotate:

```bash
# 1. New token.
NEW=$(node infra/scripts/gen-token.mjs --raw)

# 2a. Mac: update backend/.env, then restart the server.
#     (edit PINCH_TOKEN=$NEW in backend/.env)
launchctl kickstart -k "gui/$(id -u)/com.pinch.server"

# 2b. Cloud: 
fly secrets set PINCH_TOKEN="$NEW"     # triggers a redeploy/restart

# 3. Update the watch app + simulator with $NEW.
```

Old sockets that were already open are not retroactively killed by a token
change alone — bounce the server (above) to drop all live connections.

## Incident kill-switch

If you suspect the token leaked or you see activity you didn't initiate, **cut
access immediately** — fastest first:

**Mac mode**

```bash
# Kill the tunnel: the public URL goes dark instantly.
launchctl bootout "gui/$(id -u)/com.pinch.tunnel"

# And/or stop the backend.
launchctl bootout "gui/$(id -u)/com.pinch.server"

# Nuclear: take the hostname offline at Cloudflare.
cloudflared tunnel route dns --overwrite-dns pinch  # or delete the DNS record / disable the tunnel
```

**Cloud mode**

```bash
fly machine stop          # stop the Machine — endpoint goes dark
# or
fly secrets unset PINCH_TOKEN && fly deploy   # backend won't authenticate anyone
# or
fly apps destroy pinch-<you>                  # full teardown
```

**After containment:** rotate the token (above), rotate `GITHUB_TOKEN` /
`ANTHROPIC_API_KEY` if they could have been exposed, and review repo history /
host activity for anything the agent did.
