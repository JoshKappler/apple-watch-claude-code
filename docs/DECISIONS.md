# Decisions (with the why)

Made autonomously from three Opus research passes (watchOS APIs, Claude Agent SDK, connectivity).
Each call lists the alternative and why it lost. Sources are in the research; this is the distilled "why."

## 1. Engine: Claude Agent SDK, not SSH-to-a-terminal
The watch could SSH into a Mac running the Claude Code CLI. Rejected: SSH gives a raw TTY — you'd be
reading ANSI-colored scrollback through a 1.9" screen and "approving" by typing. The **Agent SDK**
(`@anthropic-ai/claude-agent-sdk`) emits *structured* events: "this is assistant text," "this is a tool
call," "this needs permission." That structure is exactly what a glanceable watch UI and TTS need, and
it's the **same engine and the same tools** as the CLI, so autonomy is identical. The watch becomes a
clean remote, not a tiny terminal.

## 2. "Dangerously skip permissions" = `permissionMode: "bypassPermissions"`
The SDK exposes the real thing. Modes: `default` (ask via `canUseTool`), `acceptEdits` (edits auto, bash
asks), `plan` (read-only), `bypassPermissions` (nothing asks — the dangerous one), plus `dontAsk`/`auto`.
We surface default/acceptEdits/plan/bypass. Entering bypass requires a guarded confirm on the watch.

## 3. Remote approval via the async `canUseTool` callback
`canUseTool(toolName, input, {signal}) => Promise<PermissionResult>` — it can **await**. So the flow is:
SDK calls it → we emit `permission_request` to the watch → we park a Promise keyed by requestId → the
watch taps ✓/✗ → the WS handler resolves the Promise → we return `{behavior:"allow"}` or
`{behavior:"deny", message}`. The `signal` lets a wrist-shake cancel abort a pending approval cleanly.
This is the load-bearing integration and it's a first-class SDK capability, not a hack.

## 4. Streaming: `includePartialMessages: true`
Without it the SDK only yields whole assistant messages. With it we get `partial_assistant` →
`stream_event` (raw Anthropic SSE: `text_delta`, `thinking_delta`). We forward text deltas as
`assistant_delta` for a live-typing feel, and emit a consolidated `assistant_message` per text block
for clean TTS readback. Tool calls come from `assistant` content blocks of type `tool_use`; tool results
from `user` messages with `tool_result` blocks. `session_id` is captured from the `system`/`init` message.

## 5. Streaming-input mode (async-iterable prompt)
We pass `prompt` as an `AsyncIterable<SDKUserMessage>` rather than a one-shot string, because that's what
unlocks **follow-up turns into a live session** and **`q.interrupt()`** (graceful stop). One-shot string
prompts can only be killed with `abort()`. The watch needs both follow-ups and a soft stop, so streaming
input it is.

## 6. Cancel = `q.interrupt()` (soft) + AbortController (hard)
Wrist-shake → `interrupt()` stops the current turn but keeps the session alive (you can immediately say
something else). A disconnect/teardown uses `abort()`/`close()`.

## 7. Auth to Anthropic: `ANTHROPIC_API_KEY`
The SDK can locally reuse Claude Code OAuth creds, but Anthropic restricts subscription/claude.ai-login
auth for third-party products built on the Agent SDK. So we ship with `ANTHROPIC_API_KEY` and document it.

> **SUPERSEDED by #10a.** Subscription auth via the Mac's Claude Code login works and is now the
> **default** (`PINCH_AUTH=subscription`). `apikey` mode (`ANTHROPIC_API_KEY`) is the opt-in alternative.

## 8. Transport: WebSocket; backend runs where the repos are; public via Cloudflare Tunnel
> **UPDATED.** The WebSocket holds for the **browser simulator**, but the physical **watch shipped on
> HTTP** (`/api/*` + a ~1.2s poll, `backend/src/httpApi.ts`): watchOS refuses `URLSessionWebSocketTask`
> on the watch's network path, so a socket was never viable on the wrist. Same `ServerMsg`/`ClientMsg`
> shapes, drained from a per-session event log. And the **default tunnel is now a stable ngrok free
> static domain** (`PINCH_NGROK_DOMAIN`), not a quick/Cloudflare tunnel — a no-domain, never-changing URL
> so restarts don't strand the baked watch build. The Cloudflare named-tunnel path remains scaffolded.

- **WebSocket** (simulator) / **HTTP poll** (watch): the session is a live stream of deltas, tool events,
  and permission round-trips. WS is the natural fit where it works; HTTP is the only thing that works on
  the watch.
- **Backend on the Mac** by default: it sees your *actual* working tree, including uncommitted changes.
  A **cloud mode** (Fly.io machine that clones from GitHub) is also provided for always-on, accepting it
  only sees pushed code. (Vercel is unsuitable for the WS/agent process — no persistent sockets even with
  Fluid Compute; it's the wrong shape for a long-running stateful agent.)
- **Cloudflare named Tunnel** for the public URL: free, full WebSocket support, your own stable hostname,
  TLS terminated at the edge. ngrok reserved domain is the zero-config fallback. Tailscale Funnel was
  rejected for this use — current WS drop/query-strip bugs make it unreliable for a cellular client.

## 9. Cellular realities baked into the protocol
- **100s Cloudflare idle timeout** → on the WebSocket (simulator) path the client sends an app-level
  `ping` every ~25s; the server replies `pong` and runs its own ws-level dead-socket sweep. (The watch's
  HTTP transport uses short requests, so a socket idle timeout doesn't apply to it.)
- **Durable delivery (watch)** → prompts go into a persisted outbox, removed only on a confirmed 2xx and
  retried otherwise; the backend dedups by client `promptId` so a retry can't double-run a turn. A
  message sent during an LTE handoff is delivered on reconnect rather than lost.
- **No background WebSocket on watchOS** → the socket only lives while the app is foreground. The client
  reconnects on activation with exponential backoff + jitter, and **resumes** the agent session
  (`resumeSessionId`) so a turn that ran while disconnected isn't lost. The backend buffers events per
  session so a reconnecting watch can be caught up.
- **APNs alert push** is the re-engagement path for long tasks (a background push wakes the user to come
  look; the app reconnects in foreground). Wired as a stub — needs your Apple push key to go live.

## 10. Gesture bindings — what's actually exposed (revised after a second verification pass)
The crown is the most versatile input, so we lean on it for everything except send. Two hard platform
facts shaped this and overturned earlier assumptions:
  - **The Digital Crown PRESS cannot be intercepted by any app** (Apple HIG: the press is reserved for
    Home/Siri/Apple Pay). So crown *rotation* is our only crown signal, and "select/confirm" is built from
    rotation, never a press.
  - **`SFSpeechRecognizer` does NOT function on watchOS** (verified — it compiles but there's no recognizer
    behind it; `AVAudioEngine` mic-tap and the new `SpeechAnalyzer` are also unavailable on the watch). The
    only working on-watch voice input is **Apple's system dictation**.

- **Double-tap = send.** `.handGestureShortcut(.primaryAction)`, **watchOS 11+ / Ultra 2+ only** (feature-
  detected; on-screen Send is the fallback). One primary action per screen, outside any ScrollView → Send
  lives on a fixed bottom bar.
- **Digital Crown = scroll · cursor · select.** Rotation scrolls the transcript; in the caret editor it
  moves the text cursor a character at a time (the "arrow keys"); in menus it highlights options. Confirm is
  rotation-based: **`CrownConfirm`** (rotate past a threshold → allow/deny on the permission gate, springs
  back if you stop short; high-risk needs a bigger throw) and **`CrownPicker`** (rotate to highlight, pause
  to commit via a dwell ring) for the mode and project menus.
- **Wrist shake = cancel.** CoreMotion `userAcceleration` magnitude over a threshold with debounce
  (foreground only).
- **Voice in = Apple system dictation**, presented programmatically via
  `WKApplication.visibleInterfaceController.presentTextInputController` (the only code-triggerable path;
  `TextFieldLink`/`TextField` are tap-only). The on-screen mic and the Action button share it. On watchOS 11
  the input reopens to the last-used method, so a dictation user lands straight in the live mic.
- **Action button (Ultra) = start dictation.** It's the one programmable physical button. Bound via the
  **Shortcuts path** (Settings → Action Button → Shortcut → the "Speak a message in Pinch" App Shortcut),
  which runs `StartDictationIntent` (`openAppWhenRun`) → `DictationRouter` → the app presents dictation. The
  direct (non-Shortcut) Action-button slot is still gated to workout/dive intents, so Shortcuts it is.
- **Back-swipe (right-to-left) = delete previous word** in the caret editor; the editor is a sheet (not a
  NavigationStack push) so this doesn't fight the un-suppressible system edge-swipe-to-go-back.
- **Taps** still work everywhere as shortcuts (✓/✗ on the permission card, tap a menu row, tap the draft to
  edit) — the crown is primary, taps are the accelerator.
- TTS readback via `AVSpeechSynthesizer`, **always paired with a haptic** because watch TTS can be silent
  without AirPods connected.

## 10a. Anthropic auth: Claude Max subscription by default
`PINCH_AUTH=subscription` (the default) uses the Claude Code login already on the Mac (keychain) — no API
key. Verified working end-to-end (a real prompt round-tripped on the subscription with no key). `PINCH_AUTH=
apikey` keeps the `ANTHROPIC_API_KEY` path. Subscription mode scrubs any stray/empty key from the env so it
can't override the keychain login.

## 11. A browser "watch simulator" is part of the build
Because there's no web runtime on watchOS and signing/installing the real app needs your Apple Developer
account interactively, the only way to verify the whole system *today* is a reference client. The
`simulator/` is a browser watch face speaking the exact same protocol (Web Speech for voice, SpeechSynthesis
for TTS). It's how the backend gets tested end-to-end now, and it doubles as a desk client.

## 12. A mock agent mode for keyless testing
The backend has a `PINCH_MOCK=1` mode that emits scripted protocol events (assistant text, a tool call, a
permission request, a result) with **no API key and no SDK call**. This let the build be verified
end-to-end before you've added your key, and it's a safe demo mode.

## Security posture (it's RCE-as-a-service)
Bearer device token validated on the WS handshake (header preferred; first-frame `auth` for the browser
sim, which can't set WS headers), constant-time compare, TLS-only, per-device revocation, project-path
allowlist with traversal rejection, rate limiting, run as a non-admin user. Optional Cloudflare Access
service-token / mTLS as an edge gate so unauthenticated traffic never reaches Node.
