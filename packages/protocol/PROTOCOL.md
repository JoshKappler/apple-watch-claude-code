# Pinch Wire Protocol v1

A single WebSocket carries the whole session. JSON text frames, one message per frame.
Every message is an object with a `type` discriminator. This file is the source of truth
both the TypeScript backend and the Swift watch client implement. The canonical machine-
readable schema lives in `src/index.ts` (Zod). Swift mirrors these shapes as `Codable` structs.

- **Transport:** WSS (TLS), path `/ws` — used by the browser simulator. The
  physical **watch uses HTTP** instead (`/api/*` + a poll loop), because watchOS
  refuses `URLSessionWebSocketTask` on the watch's network path. The HTTP API
  (`backend/src/httpApi.ts`) carries the **same `ServerMsg`/`ClientMsg` shapes
  defined below**: client messages map to `POST /api/{prompt,decision,mode,…}`,
  and server messages are drained from a per-session indexed event log via
  `GET /api/poll`. The message contracts in this file are authoritative for both.
- **Auth:** the **first** client frame MUST be `auth`. The server replies `ready` on success or
  closes with code `4401` on failure. No other frame is processed before `auth`.
- **Versioning:** `PROTOCOL_VERSION = 1`. Server includes it in `ready`; client sends it in `auth`.
  Mismatch → server sends `error{fatal:true}` and closes `4426`.
- **Keepalive:** either side may send `ping`; the peer replies `pong`. Client should ping every
  ~20s to keep the tunnel/cellular path warm and to detect dead links (see DECISIONS).
- **Unknown `type`:** receivers MUST ignore messages with an unknown `type` (forward-compat).

---

## Client → Server

### `auth`  — must be first frame
```jsonc
{ "type": "auth", "token": "<PINCH_TOKEN>", "protocolVersion": 1,
  "deviceId": "watch-ultra-1", "resumeSessionId": "abc123"? }
```
`resumeSessionId` optional — resume a prior agent session across reconnects.

### `prompt` — sent on double-tap ("send")
```jsonc
{ "type": "prompt", "text": "add a loading spinner to the settings page" }
```
Starts (or continues) an agent turn with the user's transcribed voice message.

### `permission_decision` — answer a `permission_request`
```jsonc
{ "type": "permission_decision", "requestId": "p_7", "decision": "allow",  // or "deny"
  "note": "go ahead"? , "remember": false? }
```
`remember:true` => for this session, auto-allow this tool (client-side convenience; server may honor).

### `set_mode` — change permission posture
```jsonc
{ "type": "set_mode", "mode": "bypassPermissions" }   // default | acceptEdits | plan | bypassPermissions
```
`bypassPermissions` is "dangerously skip permissions". Server emits `mode_changed` to confirm.

### `cancel` — wrist-shake / stop
```jsonc
{ "type": "cancel" }
```
Aborts the in-flight turn. Server emits `status{idle}` + `turn_complete{stopReason:"cancelled"}`.

### `select_project` / `list_projects`
```jsonc
{ "type": "list_projects" }
{ "type": "select_project", "projectId": "pinch" }
```
Pick which repo the agent operates in. Server replies `projects` / `ready`(re-scoped).

### `ping`
```jsonc
{ "type": "ping", "t": 1718999999 }
```

---

## Server → Client

### `ready` — handshake complete
```jsonc
{ "type": "ready", "protocolVersion": 1, "sessionId": "s_abc",
  "mode": "default", "project": { "id":"pinch", "name":"Pinch", "branch":"main" },
  "models": ["claude-opus-4-8","claude-sonnet-4-6"], "resumed": false }
```

### `projects`
```jsonc
{ "type": "projects", "projects": [
  { "id":"pinch", "name":"Pinch", "path":"~/dev/pinch", "branch":"main", "dirty":true } ] }
```

### `status` — glanceable state, drives watch UI + haptics
```jsonc
{ "type": "status", "state": "thinking" }   // idle|thinking|running_tool|waiting_permission|error
```

### `assistant_delta` / `assistant_message`
```jsonc
{ "type": "assistant_delta", "text": "I'll start by " }      // streaming chunk
{ "type": "assistant_message", "text": "I'll start by reading the file…" }  // full block (TTS-ready)
```
The watch renders deltas live and speaks `assistant_message` blocks aloud.

### `thinking_delta` — optional extended-thinking stream (watch may show a subtle indicator)
```jsonc
{ "type": "thinking_delta", "text": "…" }
```

### `tool_use` / `tool_result`
```jsonc
{ "type": "tool_use", "id":"t_3", "name":"Edit", "title":"Edit settings.tsx",
  "subtitle":"+12 −3", "input": { ... } }
{ "type": "tool_result", "id":"t_3", "ok": true, "summary":"applied" }
```
`title`/`subtitle` are pre-summarized by the backend for tiny screens.

### `permission_request` — needs approve/decline
```jsonc
{ "type": "permission_request", "requestId":"p_7", "tool":"Bash",
  "title":"Run command", "detail":"rm -rf build && npm run build",
  "risk":"medium",                     // low|medium|high
  "kind":"command",                    // command|edit|write|other
  "diff": "--- a/settings.tsx\n+++ b/settings.tsx\n@@ ...",   // present for edits
  "command":"rm -rf build && npm run build" }                 // present for commands
```
The watch shows a card with ✓ / ✗ (tap) and fires a prominent haptic. Ignored in `bypassPermissions`.

### `mode_changed`
```jsonc
{ "type": "mode_changed", "mode": "bypassPermissions" }
```

### `turn_complete`
```jsonc
{ "type": "turn_complete", "stopReason": "end_turn" }   // end_turn|cancelled|error|max_turns
```

### `notice` / `error`
```jsonc
{ "type": "notice", "level":"info", "message":"Reconnected; resumed session." }
{ "type": "error", "message":"Agent SDK auth failed", "fatal": true }
```

### `pong`
```jsonc
{ "type": "pong", "t": 1718999999 }
```

---

## Typical exchange

```
C → auth{token, v1}
S → ready{sessionId, mode:default, project:pinch}
C → prompt{"refactor the auth guard"}        // user double-tapped to send
S → status{thinking}
S → assistant_delta{"Let me look at "} ...
S → tool_use{Read, "Read auth.ts"}
S → tool_result{ok}
S → status{waiting_permission}
S → permission_request{p_1, Edit, diff, risk:low}
   ── watch buzzes; user taps ✓ ──
C → permission_decision{p_1, allow}
S → status{running_tool} → tool_result{ok}
S → assistant_message{"Done. I tightened the guard and added a test."}   // spoken aloud
S → turn_complete{end_turn}
S → status{idle}
```

## Mode semantics

| mode | edits | bash | behavior |
|---|---|---|---|
| `default` | ask | ask | every tool that mutates asks via `permission_request` |
| `acceptEdits` | auto | ask | file edits auto-approved; commands still ask |
| `plan` | — | — | read-only planning; no mutations |
| `bypassPermissions` | auto | auto | **dangerously skip permissions** — nothing asks. Guarded confirm on the watch before entering. |
