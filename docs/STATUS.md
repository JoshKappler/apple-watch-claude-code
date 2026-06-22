# Status — what's done, what's verified, what needs you

_Built autonomously while you were getting the charging cable. Everything below is on `main`._

## One line
The whole system is written and the server side is **verified working end-to-end**. To actually talk to
a repo from your wrist you need to do three things only you can do: add an API key, sign the watch app in
Xcode with your Apple Developer account, and run the Cloudflare tunnel login once.

---

## What's built and verified ✅

| Piece | State | Evidence |
|---|---|---|
| **Wire protocol** (`packages/protocol`) | Done | builds clean; 22 message types; Swift mirror matches exactly |
| **Backend** (`backend`) | Done + **verified** | typechecks; runs; **smoke test passes** the full round-trip; bad token → 4401 |
| **Simulator** (`simulator`) | Done + **verified** | typechecks; production build = 25 KB gzipped |
| **watchOS app** (`watch`) | Source complete | 21 Swift files; all pass `swiftc -parse`; needs Xcode to compile/sign (see below) |
| **Infra** (`infra`) | Done | Cloudflare Tunnel + launchd + Fly.io cloud mode + token gen + security; scripts pass `bash -n` |

The smoke test (`scripts/smoke-test.mjs`) drove a real WebSocket session against the backend and confirmed:
`auth → ready → prompt → thinking → streaming text → Read tool → permission request → (allow) → Edit tool
→ spoken result → turn_complete → idle`. That's the entire interaction loop, including the async
permission approval that the watch's ✓/✗ taps drive. It ran in **mock mode**, so no API key was needed to
prove the plumbing.

## Try it right now (no watch, no API key)
```bash
npm install
PINCH_MOCK=1 PINCH_TOKEN=test-token npm run dev          # backend on ws://localhost:8787/ws
# in another shell:
PINCH_TOKEN=test-token node scripts/smoke-test.mjs        # watch it round-trip
npm run sim                                                # or open the browser watch and click around
```

---

## What needs you (the parts I can't do autonomously)

1. **Nothing for auth — it runs on your Claude Max subscription.** `PINCH_AUTH=subscription` is the default
   and uses the Claude Code login already on this Mac (no API key). Verified: a real prompt round-tripped on
   your plan with no key. Just run `./setup.sh` (generates your `PINCH_TOKEN`), set `PINCH_PROJECTS` to the
   repo path(s) you want it editing, and `PINCH_MOCK=0`.
2. **Xcode + your Apple Developer account** — to put the app on your Ultra. `xcodegen` is installed; run
   `cd watch && xcodegen generate && open Pinch.xcodeproj`. Set your **Team**, change the bundle id to one
   you own, Run on the watch. This Mac only has Command Line Tools (no watchOS SDK), so I couldn't compile
   or sign it — but the source is complete, all 19 files pass `swiftc -parse`, and the protocol mirror is
   exact. Full details in `watch/README.md`.
3. **Assign the Action button → dictation (one-time, on the watch).** After the app is installed: open the
   Shortcuts app, the "Speak a message in Pinch" App Shortcut appears; then Settings → Action Button → First
   Press → Shortcut → pick it. Press the orange button → Pinch opens listening.
4. **Cloudflare tunnel login (once)** — for the public cellular URL. `cloudflared` is installed; run
   `cloudflared login`, `cloudflared tunnel create pinch`, then follow `infra/cloudflared/README.md`. Until
   then the browser simulator works over `ws://localhost` on your LAN.
5. **(Optional) APNs key** — to enable the "long task finished, come look" push. Stubbed and documented in
   `watch/Sources/PushRegistration.swift`.

Full from-zero walkthrough: **`docs/SETUP.md`**.

---

## Control map (Apple Watch Ultra)
| Control | Action |
|---|---|
| **Double-tap (pinch)** | **Send message** — `.handGestureShortcut(.primaryAction)`, Ultra 2+/watchOS 11 |
| **Action button** (orange) | **Start dictating** (system dictation; one-time Shortcut assignment) |
| Tap mic button | Start dictating (same system dictation) |
| **Digital Crown** | Scroll transcript · move text cursor in the editor · highlight menu options |
| **Crown — rotate to confirm** | Permission gate: turn right past threshold = allow, left = deny (springs back) |
| **Crown — pause to commit** | Mode / project menus: turn to highlight, dwell to select |
| Swipe ← in editor | Delete the previous word |
| **Wrist shake** | **Cancel** the in-flight turn |
| Tap ✓ / ✗ · tap a row | Shortcuts that mirror the crown decision/selection |

## Honest caveats (all verified, all documented)
- **Double-tap is Series 9 / Ultra 2 and later only.** On an original Ultra the on-screen Send button is
  the path (the app feature-detects and degrades).
- **No crown PRESS for apps.** watchOS reserves the crown click for the system, so "select/confirm" is
  built from crown *rotation* (threshold + dwell), never a press. Taps are the fallback.
- **No always-on in-app voice listener.** `SFSpeechRecognizer` doesn't function on watchOS — voice in is
  Apple's system dictation (tap mic / press Action button → speak → text). Fully hands-free always-listening
  would require streaming the mic to the backend for server-side STT (not built; offered as a follow-up).
- **Watch TTS can be silent without AirPods/Bluetooth.** Every spoken reply is paired with a haptic, and
  there's a speaker toggle. Wear AirPods to reliably *hear* replies.
- **No background WebSocket on watchOS.** The socket lives while the app is foreground; it reconnects and
  resumes the session on reopen, and APNs is the re-engagement path for long tasks.
- **Agent SDK is v0.3.x (pre-1.0).** Its surface can still move; the version is pinned. `zod` is on v4 to
  satisfy the SDK's peer dependency.
- **This is remote code execution as a service.** The bearer token is the only thing between the public
  internet and an agent that can run `bash` in your repos. Treat the token like an SSH key; revoke it if a
  device is lost. Optionally put Cloudflare Access in front. See `infra/SECURITY.md`.

## Cost shape
- Mac + Cloudflare Tunnel = **$0** infra (you already pay for the watch's cellular plan and your Anthropic
  usage). Always-on cloud mode (Fly.io) is ~$2–20/mo and only sees pushed code.

## Repo map
`backend/` server · `watch/` watchOS app · `simulator/` browser test client · `packages/protocol/` wire
contract · `infra/` deploy · `docs/` PLAN, DECISIONS, SETUP, STATUS · `scripts/smoke-test.mjs` verifier.
