# @pinch/backend

The Pinch backend: a WebSocket server that bridges the **Claude Agent SDK** to the
Pinch wire protocol (`@pinch/protocol`). This is the process the watch (or the
browser simulator) connects to. It runs where your repos live so the agent sees
your actual working tree.

- **Two transports, one session model.** A WebSocket at `/ws` (JSON frames) for
  the browser simulator, and HTTP request/response + polling at `/api/*` for the
  physical watch (watchOS refuses WebSockets on the watch's network path). Both
  share the session map, agent wiring, event log, and resume rule via
  `sessionRegistry.ts`.
- Bearer-token auth (header preferred, first-frame `auth` fallback for browsers).
- Streaming agent turns, remote tool approvals, durable per-session resume.
- A keyless **mock mode** for end-to-end testing without an API key.
- Every real session appends a watch-orientation note to the Claude Code system
  prompt (replies read aloud + tiny screen → plain text, brief, numbered prose).

## Requirements

- Node 20+
- Anthropic auth: by default `PINCH_AUTH=subscription` uses the Mac's Claude Code
  login (Claude Max/Pro keychain — no key). Set `PINCH_AUTH=apikey` +
  `ANTHROPIC_API_KEY` to pay per token instead. Mock mode needs neither.

## Setup

```bash
cp .env.example .env
# edit .env: set PINCH_TOKEN, PINCH_PROJECT_ROOTS, and auth (subscription by default)
# (or run ../setup.sh from the repo root, which fills in PINCH_TOKEN for you)
```

Generate a strong token:

```bash
openssl rand -hex 32
```

> Install is handled centrally from the monorepo root (`npm install` there).
> Don't run `npm install` inside this package.

## Run

### Mock mode (no API key, no SDK)

The fastest way to verify the whole system. Emits a scripted turn:
thinking → streamed assistant text → `Read` tool → an `Edit` permission request
(with a diff) → on approve, a result + spoken summary → turn complete.

```bash
PINCH_MOCK=1 PINCH_TOKEN=dev-token npm run dev
```

### Real mode (Claude Agent SDK)

```bash
# .env has PINCH_TOKEN, PINCH_PROJECT_ROOTS, and auth set (subscription by default)
npm run dev      # tsx watch
# or
npm run build && npm start
```

## Environment

| Var | Default | Notes |
|---|---|---|
| `PORT` | `8787` | WS path is `/ws`; watch HTTP path is `/api/*`; health is `/health` |
| `PINCH_TOKEN` | — | **required** — bearer token the client must present |
| `PINCH_AUTH` | `subscription` | `subscription` (Mac's Claude Code login, no key) or `apikey` |
| `ANTHROPIC_API_KEY` | — | required only when `PINCH_AUTH=apikey` |
| `PINCH_PROJECT_ROOTS` | — | comma-separated parent dirs to scan; every child repo is a selectable project. At least one of this / `PINCH_PROJECTS` required in real mode |
| `PINCH_PROJECTS` | — | optional explicit absolute repo allowlist |
| `PINCH_MOCK` | `0` | `1` → scripted mock agent, no SDK, no key |
| `PINCH_MODEL` | `claude-opus-4-8` | model id passed to the SDK |
| `LOG_LEVEL` | `info` | `trace`…`fatal` |

> `PINCH_NGROK_DOMAIN` is read by the always-on launchd service installer
> (`npm run up`), not by the backend itself.

## Auth

Two ways to present the token (both validated with a constant-time compare):

1. **Header** (native clients): `Authorization: Bearer <PINCH_TOKEN>` on the WS
   upgrade. A wrong header is rejected at the HTTP upgrade (no socket created).
2. **First frame** (browsers, which can't set WS headers): the first frame must be
   `{ "type":"auth", "token":"…", "protocolVersion":1 }`. No other frame is
   processed before `auth`.

Close codes: `4401` auth failed, `4426` protocol mismatch, `4500` internal.

## Verify with the simulator

The browser watch simulator (`../simulator`) speaks the exact same protocol and is
the end-to-end test rig (decision #11/#12 in `docs/DECISIONS.md`).

```bash
# terminal 1 — backend in mock mode
PINCH_MOCK=1 PINCH_TOKEN=dev-token npm run dev

# terminal 2 — simulator (from repo root)
npm run sim
```

In the simulator, connect to `ws://localhost:8787/ws` with token `dev-token`,
send a prompt, and you should see the scripted turn stream in, including the
`Edit` permission card. Approve it to see the result and spoken summary. Switch to
real mode by dropping `PINCH_MOCK` once your `ANTHROPIC_API_KEY` is set.

### Quick raw check (no simulator)

```bash
# health endpoint
curl localhost:8787/health
```

## Architecture

| File | Role |
|---|---|
| `src/index.ts` | bootstrap + graceful shutdown |
| `src/config.ts` | env load + Zod validation |
| `src/log.ts` | pino logger (pretty in dev) |
| `src/wsServer.ts` | http + `ws` server, upgrade auth, routes `/api/*` + `/health` |
| `src/httpApi.ts` | the watch's HTTP transport: session/prompt/poll/decision/mode/config/cancel/projects |
| `src/connection.ts` | per-WS-connection: auth, routing, session, resume buffer, heartbeat |
| `src/sessionRegistry.ts` | shared session map, indexed event log (ring), resume + idle sweep |
| `src/sessionStore.ts` | durable resume records → `.pinch-sessions.json` (survives restart) |
| `src/session.ts` | real Agent SDK session (lazy `import()`); holds the watch-orientation system append |
| `src/mockSession.ts` | scripted keyless session (no SDK) |
| `src/sessionTypes.ts` | shared session interface + tool/permission summaries + thinking config |
| `src/approvals.ts` | `canUseTool` ↔ `permission_decision` approval registry |
| `src/projects.ts` | project registry (scan roots + allowlist) + path guard + git branch/dirty |

### Why a lazy SDK import?

`src/session.ts` imports `@anthropic-ai/claude-agent-sdk` only via a dynamic
`import()` inside the first turn. Mock mode and the whole server therefore compile
and run even if the SDK package is heavy or absent and even without an API key.

### Resume & heartbeat

Each session keeps a bounded event buffer. On reconnect with `resumeSessionId`,
the connection re-attaches to the live session and replays the buffer so a turn
that ran while the watch was backgrounded isn't lost. Two heartbeats run: the
app-level `ping`→`pong`, and a ws-level ping that `terminate()`s a socket after 2
missed pongs.
