# Pinch Simulator

A browser-based **Apple Watch Ultra** that speaks the exact Pinch wire protocol over
WebSocket. It's the reference client used to verify the whole system end-to-end —
no Apple hardware, no Xcode signing — and it doubles as a desk client.

Vanilla TypeScript + Vite. No UI framework. Imports message types and validators
from [`@pinch/protocol`](../packages/protocol).

## Run

From the repo root:

```bash
npm run sim
# ── or ──
npm run dev -w simulator
```

Vite prints a local URL (default <http://localhost:5273>). Open it, then:

1. Click the **⚙ gear** (top-right of the watch face).
2. Set **Server URL** (default `ws://localhost:8787/ws`) and your **device token**.
3. **Save & connect.** The connection dot goes green when `ready` arrives.
4. Tap the **project chip** to list/select a repo, then talk to it.

Settings persist to `localStorage`. With a token already saved, the app
auto-connects on load and resumes the agent session across reconnects.

> Run the backend first. For a keyless smoke test, start it in mock mode
> (`PINCH_MOCK=1`) — it emits scripted protocol events so you can exercise the
> whole UI (streaming text, a tool call, a permission card, TTS) without an API key.

## Controls (these mirror the real watch bindings)

| On the watch | Here in the simulator |
| --- | --- |
| **Double-tap = send** | the orange **Send** button (or press **Enter**; Shift+Enter = newline) |
| **Push-to-talk** | **hold the 🎙 mic** to dictate into the compose buffer; release to settle |
| **Digital Crown = scroll** | **wheel or drag** over the right-edge crown — scrolls the transcript, and scrubs the diff when a permission card is open |
| **Wrist-shake = stop** | the **Stop** button → sends `cancel` |
| **Permission ✓ / ✗** | tap the card buttons → `permission_decision`; the card is colored by risk and shows the diff/command |
| **Mode** | the mode menu (default · accept edits · plan · **bypass**); entering bypass pops a guarded confirm |
| **TTS readback** | `assistant_message` blocks are spoken via `speechSynthesis`; the 🔊 button mutes, and the face pulses while speaking |

## How it's wired

- `src/ws.ts` — typed WebSocket client. Authenticates by sending the **first frame**
  as `auth` (browsers can't set WS headers), validates every inbound frame with
  `parseServerMsg`, reconnects with exponential backoff + jitter, sends an app-level
  `ping` every 25s, and resumes via `resumeSessionId`.
- `src/ui.ts` — the watch face: transcript, status ring, tool chips, permission
  cards, mode menu, compose bar, settings/projects panels.
- `src/voice.ts` — Web Speech dictation + `speechSynthesis` TTS, both feature-detected.
- `src/main.ts` — the controller that maps UI intents → `ClientMsg`s and inbound
  `ServerMsg`s → UI updates.

## Browser caveats

- **Dictation (push-to-talk) is Chrome/Edge only.** The Web Speech *recognition* API
  (`webkitSpeechRecognition`) doesn't ship in Firefox or Safari. The mic button is
  disabled there with a tooltip — just type instead.
- **TTS readback** (`speechSynthesis`) works in all current browsers. Some need a
  prior user interaction before audio plays; clicking anywhere satisfies that.
- Use **`ws://`** for localhost. A public deployment behind TLS must use **`wss://`**
  (a secure page can't open an insecure socket).
