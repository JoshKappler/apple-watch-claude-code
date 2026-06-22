/**
 * Typed WebSocket client for the Pinch protocol.
 *
 * Responsibilities:
 *  - connect to the backend and authenticate with the FIRST frame as `auth`
 *    (browsers can't set WS headers, so the token rides in the first message).
 *  - validate every inbound frame with `parseServerMsg` before handing it up.
 *  - reconnect with exponential backoff + jitter; resume the agent session via
 *    `resumeSessionId` once we've learned one from a prior `ready`.
 *  - app-level heartbeat: `ping` every ~25s to keep the cellular/tunnel path warm
 *    (Cloudflare's idle timeout is 100s — see docs/DECISIONS.md §9).
 *
 * It is intentionally framework-free: a tiny typed event emitter, one socket.
 */
import {
  parseServerMsg,
  PROTOCOL_VERSION,
  type ClientMsg,
  type ServerMsg,
} from "@pinch/protocol";

export type ConnState = "disconnected" | "connecting" | "authenticating" | "ready";

export interface WsConfig {
  url: string;
  token: string;
  deviceId?: string;
}

type Events = {
  state: (s: ConnState) => void;
  message: (m: ServerMsg) => void;
  /** Raw frame that failed protocol validation — surfaced for debugging only. */
  malformed: (raw: string) => void;
  /** Latency sample (ms) from a ping/pong round-trip. */
  latency: (ms: number) => void;
};

const HEARTBEAT_MS = 25_000;
const BACKOFF_BASE_MS = 500;
const BACKOFF_MAX_MS = 15_000;

export class PinchClient {
  private cfg: WsConfig;
  private ws: WebSocket | null = null;
  private state: ConnState = "disconnected";

  private sessionId: string | null = null;
  private wantOpen = false; // user intends to be connected (drives reconnect)
  private attempt = 0;
  private heartbeat: ReturnType<typeof setInterval> | null = null;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private pingSentAt = 0;

  // Stored loosely; the public on/emit keep the strong types at the boundary.
  private listeners = new Map<keyof Events, Set<(...args: unknown[]) => void>>();

  constructor(cfg: WsConfig) {
    this.cfg = cfg;
  }

  on<K extends keyof Events>(event: K, fn: Events[K]): () => void {
    let set = this.listeners.get(event);
    if (!set) {
      set = new Set();
      this.listeners.set(event, set);
    }
    const wrapped = fn as (...args: unknown[]) => void;
    set.add(wrapped);
    return () => {
      set?.delete(wrapped);
    };
  }

  private emit<K extends keyof Events>(event: K, ...args: Parameters<Events[K]>) {
    const set = this.listeners.get(event);
    if (!set) return;
    for (const fn of set) fn(...args);
  }

  getState(): ConnState {
    return this.state;
  }

  getSessionId(): string | null {
    return this.sessionId;
  }

  /** Update connection params (e.g. from the settings panel). Reconnects if open. */
  configure(cfg: WsConfig) {
    this.cfg = cfg;
    if (this.wantOpen) {
      this.sessionId = null; // a new server/token starts a fresh session
      this.reconnectNow();
    }
  }

  connect() {
    this.wantOpen = true;
    this.attempt = 0;
    this.open();
  }

  disconnect() {
    this.wantOpen = false;
    this.clearTimers();
    if (this.ws) {
      const ws = this.ws;
      this.ws = null;
      try {
        ws.close(1000, "client closing");
      } catch {
        /* ignore */
      }
    }
    this.setState("disconnected");
  }

  /** Force an immediate reconnect (used when config changes). */
  private reconnectNow() {
    this.clearTimers();
    if (this.ws) {
      try {
        this.ws.close(1000, "reconnecting");
      } catch {
        /* ignore */
      }
      this.ws = null;
    }
    this.attempt = 0;
    this.open();
  }

  private open() {
    if (!this.wantOpen) return;
    this.setState("connecting");
    let ws: WebSocket;
    try {
      ws = new WebSocket(this.cfg.url);
    } catch {
      this.scheduleReconnect();
      return;
    }
    this.ws = ws;

    ws.addEventListener("open", () => {
      if (this.ws !== ws) return;
      this.attempt = 0;
      this.setState("authenticating");
      // FIRST frame must be `auth` (see PROTOCOL.md). Include resumeSessionId
      // if we have one so a turn that ran while we were offline isn't lost.
      this.rawSend({
        type: "auth",
        token: this.cfg.token,
        protocolVersion: PROTOCOL_VERSION,
        deviceId: this.cfg.deviceId ?? "sim",
        ...(this.sessionId ? { resumeSessionId: this.sessionId } : {}),
      });
    });

    ws.addEventListener("message", (ev) => {
      if (this.ws !== ws) return;
      const raw = typeof ev.data === "string" ? ev.data : "";
      const msg = parseServerMsg(raw);
      if (!msg) {
        this.emit("malformed", raw);
        return;
      }
      this.handle(msg);
    });

    ws.addEventListener("close", () => {
      if (this.ws !== ws) return;
      this.ws = null;
      this.stopHeartbeat();
      if (this.wantOpen) {
        this.setState("connecting");
        this.scheduleReconnect();
      } else {
        this.setState("disconnected");
      }
    });

    ws.addEventListener("error", () => {
      // The close handler drives reconnect; error is informational.
      if (this.ws !== ws) return;
      try {
        ws.close();
      } catch {
        /* ignore */
      }
    });
  }

  private handle(msg: ServerMsg) {
    switch (msg.type) {
      case "ready":
        this.sessionId = msg.sessionId;
        this.setState("ready");
        this.startHeartbeat();
        break;
      case "pong": {
        if (this.pingSentAt) {
          this.emit("latency", Math.round(performance.now() - this.pingSentAt));
          this.pingSentAt = 0;
        }
        break;
      }
      case "error":
        // Fatal errors (auth/version) will be followed by a server close.
        break;
    }
    this.emit("message", msg);
  }

  /** Send a typed client frame. No-op (returns false) if not ready. */
  send(msg: ClientMsg): boolean {
    if (this.state !== "ready") return false;
    return this.rawSend(msg);
  }

  private rawSend(msg: ClientMsg): boolean {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return false;
    try {
      this.ws.send(JSON.stringify(msg));
      return true;
    } catch {
      return false;
    }
  }

  private startHeartbeat() {
    this.stopHeartbeat();
    this.heartbeat = setInterval(() => {
      this.pingSentAt = performance.now();
      const ok = this.rawSend({ type: "ping", t: Date.now() });
      if (!ok) this.pingSentAt = 0;
    }, HEARTBEAT_MS);
  }

  private stopHeartbeat() {
    if (this.heartbeat) {
      clearInterval(this.heartbeat);
      this.heartbeat = null;
    }
    this.pingSentAt = 0;
  }

  private scheduleReconnect() {
    if (!this.wantOpen || this.reconnectTimer) return;
    // Exponential backoff with full jitter.
    const exp = Math.min(BACKOFF_MAX_MS, BACKOFF_BASE_MS * 2 ** this.attempt);
    const delay = Math.random() * exp;
    this.attempt++;
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      this.open();
    }, delay);
  }

  private clearTimers() {
    this.stopHeartbeat();
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
  }

  private setState(s: ConnState) {
    if (this.state === s) return;
    this.state = s;
    this.emit("state", s);
  }
}
