/**
 * Per-connection handler.
 *
 * Owns one WebSocket: the auth handshake, inbound frame routing, the agent
 * session (mock or real per config), a per-session event buffer for resume, and
 * the app-level + ws-level heartbeat. One Connection ≈ one watch attached to one
 * agent session.
 *
 * Auth model (matches PROTOCOL.md + security posture in DECISIONS.md):
 *  - The upgrade handler may pre-authenticate via the Authorization header.
 *  - Otherwise the FIRST frame MUST be `auth`; no other frame is processed first.
 *  - Token compared in constant time; protocolVersion validated (close 4426).
 */
import { timingSafeEqual } from "node:crypto";
import { randomUUID } from "node:crypto";
import type { WebSocket } from "ws";
import {
  CloseCode,
  PROTOCOL_VERSION,
  parseClientMsg,
  srv,
  type ClientMsg,
  type PermissionMode,
  type ServerMsg,
} from "@pinch/protocol";
import { config } from "./config.js";
import { log } from "./log.js";
import { ApprovalRegistry } from "./approvals.js";
import { projectRegistry, type Project } from "./projects.js";
import type { AgentSession, SessionDeps } from "./sessionTypes.js";
import { createMockSession } from "./mockSession.js";
// session.js imports the SDK only lazily (inside start()), so importing the
// factory here does NOT pull the SDK in at module scope.
import { createClaudeSession } from "./session.js";

/** Max buffered events retained per session for reconnect replay. */
const EVENT_BUFFER_LIMIT = 500;
/** ws-level ping cadence and the missed-pong budget before terminate(). */
const WS_PING_INTERVAL_MS = 25_000;
const MAX_MISSED_PONGS = 2;

/**
 * Session state that must SURVIVE a socket dropping so a reconnecting watch can
 * resume. Keyed by Anthropic session id. Holds the live agent + a replay buffer.
 */
interface SessionState {
  sessionId: string;
  agent: AgentSession;
  approvals: ApprovalRegistry;
  project: Project;
  mode: PermissionMode;
  buffer: ServerMsg[];
  /** The currently attached socket (if any). Cleared on disconnect. */
  socket: WebSocket | null;
}

/** Module-level registry of live sessions, so resume works across sockets. */
const sessions = new Map<string, SessionState>();

/** Constant-time token comparison that tolerates length differences. */
function tokensMatch(provided: string, expected: string): boolean {
  const a = Buffer.from(provided);
  const b = Buffer.from(expected);
  if (a.length !== b.length) {
    // Still run a compare to keep timing uniform, then fail.
    timingSafeEqual(a, a);
    return false;
  }
  return timingSafeEqual(a, b);
}

export interface ConnectionOpts {
  ws: WebSocket;
  /** True if the upgrade handler already validated the bearer header. */
  preAuthed: boolean;
}

export class Connection {
  private readonly ws: WebSocket;
  private authed: boolean;
  private state: SessionState | null = null;
  private missedPongs = 0;
  private wsPingTimer: NodeJS.Timeout | null = null;
  private closed = false;

  constructor(opts: ConnectionOpts) {
    this.ws = opts.ws;
    this.authed = opts.preAuthed;

    this.ws.on("message", (data) => this.onMessage(data));
    this.ws.on("close", () => this.onClose());
    this.ws.on("error", (err) => log.warn({ err }, "ws error"));
    this.ws.on("pong", () => {
      this.missedPongs = 0;
    });

    this.startWsHeartbeat();
  }

  /* ───────────────────────────── inbound ───────────────────────────── */

  private onMessage(data: unknown): void {
    const raw = typeof data === "string" ? data : String(data);
    const msg = parseClientMsg(raw);
    if (!msg) {
      // Unknown/malformed frame: ignore per forward-compat rule.
      log.debug("ignored malformed/unknown client frame");
      return;
    }

    // Before auth completes, only `auth` is processed.
    if (!this.authed && msg.type !== "auth") {
      log.warn({ type: msg.type }, "frame before auth; ignoring");
      return;
    }

    switch (msg.type) {
      case "auth":
        void this.handleAuth(msg);
        break;
      case "prompt":
        void this.handlePrompt(msg.text);
        break;
      case "permission_decision":
        this.handlePermissionDecision(msg);
        break;
      case "set_mode":
        this.handleSetMode(msg.mode);
        break;
      case "cancel":
        void this.handleCancel();
        break;
      case "list_projects":
        void this.handleListProjects();
        break;
      case "select_project":
        void this.handleSelectProject(msg.projectId);
        break;
      case "ping":
        this.send(srv.pong(msg.t), { buffer: false });
        break;
    }
  }

  private async handleAuth(
    msg: Extract<ClientMsg, { type: "auth" }>,
  ): Promise<void> {
    if (this.authed && this.state) {
      // Already authed (header path or duplicate). Ignore re-auth.
      return;
    }

    if (!tokensMatch(msg.token, config.token)) {
      log.warn("auth failed: bad token");
      this.fatalClose(CloseCode.AUTH_FAILED, "auth failed");
      return;
    }
    if (msg.protocolVersion !== PROTOCOL_VERSION) {
      log.warn(
        { got: msg.protocolVersion, want: PROTOCOL_VERSION },
        "protocol mismatch",
      );
      this.send(
        srv.error(
          `protocol mismatch: server ${PROTOCOL_VERSION}, client ${msg.protocolVersion}`,
          true,
        ),
        { buffer: false },
      );
      this.fatalClose(CloseCode.PROTOCOL_MISMATCH, "protocol mismatch");
      return;
    }

    this.authed = true;
    await this.attachSession(msg.resumeSessionId);
  }

  /** Create a fresh session, or re-attach to an existing one for resume. */
  private async attachSession(resumeId?: string): Promise<void> {
    const existing = resumeId ? sessions.get(resumeId) : undefined;
    if (existing) {
      existing.socket?.close(); // evict any stale socket
      existing.socket = this.ws;
      this.state = existing;
      const ref = await projectRegistry.toRef(existing.project);
      this.send(
        srv.ready({
          sessionId: existing.sessionId,
          mode: existing.mode,
          project: ref,
          models: [config.model],
          resumed: true,
        }),
        { buffer: false },
      );
      this.send(srv.notice("info", "Reconnected; resumed session."), {
        buffer: false,
      });
      this.replayBuffer();
      return;
    }

    const project = projectRegistry.default();
    if (!project && !config.mock) {
      this.send(srv.error("no projects configured", true), { buffer: false });
      this.fatalClose(CloseCode.INTERNAL, "no projects");
      return;
    }
    // Mock mode can run without a real project root.
    const proj: Project =
      project ?? { id: "mock", name: "mock", root: process.cwd() };

    const state = this.createSession(proj, "default");
    this.state = state;
    sessions.set(state.sessionId, state);

    const ref = config.mock
      ? { id: proj.id, name: proj.name, path: proj.root }
      : await projectRegistry.toRef(proj);
    this.send(
      srv.ready({
        sessionId: state.sessionId,
        mode: state.mode,
        project: ref,
        models: [config.model],
        resumed: false,
      }),
      { buffer: false },
    );
  }

  /** Build a SessionState (agent + approvals + buffer) for a project. */
  private createSession(project: Project, mode: PermissionMode): SessionState {
    const approvals = new ApprovalRegistry();
    const sessionId = `s_${randomUUID().slice(0, 12)}`;

    const state: SessionState = {
      sessionId,
      agent: undefined as unknown as AgentSession, // set just below
      approvals,
      project,
      mode,
      buffer: [],
      socket: this.ws,
    };

    const deps: SessionDeps = {
      send: (m) => this.dispatchFromSession(state, m),
      approvals,
      cwd: project.root,
      model: config.model,
      initialMode: mode,
      onSessionId: (sdkId) => {
        // Map the SDK's own session id alongside ours so resume:sdkId works.
        if (sdkId && !sessions.has(sdkId)) sessions.set(sdkId, state);
      },
    };

    state.agent = config.mock
      ? createMockSession(deps)
      : createClaudeSession(deps);
    return state;
  }

  private async handlePrompt(text: string): Promise<void> {
    const state = this.state;
    if (!state) return;
    await state.agent.start(text);
  }

  private handlePermissionDecision(
    msg: Extract<ClientMsg, { type: "permission_decision" }>,
  ): void {
    const state = this.state;
    if (!state) return;
    const ok = state.approvals.decide(msg.requestId, {
      decision: msg.decision,
      note: msg.note,
    });
    if (!ok) log.debug({ requestId: msg.requestId }, "stale permission decision");
  }

  private handleSetMode(mode: PermissionMode): void {
    const state = this.state;
    if (!state) return;
    state.mode = mode;
    state.agent.setMode(mode);
    this.send(srv.modeChanged(mode));
  }

  private async handleCancel(): Promise<void> {
    const state = this.state;
    if (!state) return;
    await state.agent.interrupt();
    this.send(srv.status("idle"));
    this.send(srv.turnComplete("cancelled"));
  }

  private async handleListProjects(): Promise<void> {
    const refs = config.mock
      ? projectRegistry.list().map((p) => ({ id: p.id, name: p.name, path: p.root }))
      : await projectRegistry.listRefs();
    this.send(srv.projects(refs), { buffer: false });
  }

  private async handleSelectProject(projectId: string): Promise<void> {
    const project = projectRegistry.get(projectId);
    if (!project) {
      this.send(srv.notice("warn", `unknown project: ${projectId}`));
      return;
    }
    // Allowlist guard: belt-and-suspenders even though the id came from registry.
    if (!config.mock && !projectRegistry.isPathAllowed(project.root)) {
      this.send(srv.error("project path not allowed", false));
      return;
    }

    const old = this.state;
    if (old) {
      await old.agent.cancel();
      sessions.delete(old.sessionId);
    }

    const state = this.createSession(project, old?.mode ?? "default");
    this.state = state;
    sessions.set(state.sessionId, state);

    const ref = config.mock
      ? { id: project.id, name: project.name, path: project.root }
      : await projectRegistry.toRef(project);
    this.send(
      srv.ready({
        sessionId: state.sessionId,
        mode: state.mode,
        project: ref,
        models: [config.model],
        resumed: false,
      }),
      { buffer: false },
    );
  }

  /* ───────────────────────────── outbound ───────────────────────────── */

  /** A session-originated frame: buffer it for resume, then send if attached. */
  private dispatchFromSession(state: SessionState, msg: ServerMsg): void {
    state.buffer.push(msg);
    if (state.buffer.length > EVENT_BUFFER_LIMIT) state.buffer.shift();
    if (state.socket && state.socket === this.ws && !this.closed) {
      this.rawSend(msg);
    } else if (state.socket && state.socket !== this.ws) {
      // A newer socket owns this session now; let that connection's send run.
      // (dispatchFromSession is bound to the connection that created the state,
      //  but socket ownership moved — write directly to the current socket.)
      trySocketSend(state.socket, msg);
    }
  }

  /** Send a frame on this connection. `buffer:false` for transient frames. */
  private send(msg: ServerMsg, opts: { buffer?: boolean } = {}): void {
    if (opts.buffer !== false && this.state) {
      this.state.buffer.push(msg);
      if (this.state.buffer.length > EVENT_BUFFER_LIMIT)
        this.state.buffer.shift();
    }
    this.rawSend(msg);
  }

  private rawSend(msg: ServerMsg): void {
    if (this.closed) return;
    trySocketSend(this.ws, msg);
  }

  /** Replay the per-session buffer to a freshly reconnected watch. */
  private replayBuffer(): void {
    if (!this.state) return;
    for (const msg of this.state.buffer) this.rawSend(msg);
  }

  /* ───────────────────────────── heartbeat ───────────────────────────── */

  private startWsHeartbeat(): void {
    this.wsPingTimer = setInterval(() => {
      if (this.closed) return;
      if (this.missedPongs >= MAX_MISSED_PONGS) {
        log.warn("dead socket: terminating after missed pongs");
        this.ws.terminate();
        return;
      }
      this.missedPongs += 1;
      try {
        this.ws.ping();
      } catch {
        this.ws.terminate();
      }
    }, WS_PING_INTERVAL_MS);
    // Don't keep the process alive solely for the heartbeat.
    this.wsPingTimer.unref?.();
  }

  /* ───────────────────────────── lifecycle ───────────────────────────── */

  private fatalClose(code: number, reason: string): void {
    this.closed = true;
    if (this.wsPingTimer) clearInterval(this.wsPingTimer);
    try {
      this.ws.close(code, reason);
    } catch {
      this.ws.terminate();
    }
  }

  private onClose(): void {
    this.closed = true;
    if (this.wsPingTimer) clearInterval(this.wsPingTimer);
    // Detach the socket but KEEP the session alive for resume. A reconnecting
    // watch (resumeSessionId) re-attaches and gets the buffered catch-up.
    if (this.state && this.state.socket === this.ws) {
      this.state.socket = null;
    }
    log.info({ sessionId: this.state?.sessionId }, "connection closed");
  }
}

/** Write a frame to a socket, swallowing send errors on a dying socket. */
function trySocketSend(ws: WebSocket, msg: ServerMsg): void {
  try {
    if (ws.readyState === ws.OPEN) ws.send(JSON.stringify(msg));
  } catch (err) {
    log.debug({ err }, "send failed");
  }
}
