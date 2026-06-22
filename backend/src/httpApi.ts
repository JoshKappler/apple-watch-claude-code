/**
 * HTTP request/response + polling API for the watchOS client.
 *
 * On the physical Apple Watch, plain HTTPS works but URLSessionWebSocketTask is
 * refused by the OS — so the watch transport moved to HTTP. This module exposes
 * the SAME session lifecycle as the WS path (create/resume, prompt, decisions,
 * mode, cancel, projects) but drives a SOCKETLESS session: outbound ServerMsgs
 * land in the session's indexed event log, and the client drains them via /poll.
 *
 * All routes live under /api/ so they never collide with /ws or /health. Every
 * request requires `Authorization: Bearer <token>` (same constant-time check as
 * the WS upgrade). Bad/missing token → 401; unknown /api path → 404.
 *
 * The agent wiring, session map, resume rule, event log, and idle sweep are all
 * shared with the WS path via sessionRegistry.ts — nothing here is duplicated.
 */
import type { IncomingMessage, ServerResponse } from "node:http";
import { timingSafeEqual } from "node:crypto";
import { srv, PROTOCOL_VERSION } from "@pinch/protocol";
import { config } from "./config.js";
import { log } from "./log.js";
import { projectRegistry } from "./projects.js";
import {
  attachAgent,
  createSession,
  defaultProject,
  ensureSessionSweep,
  pushEvent,
  readEvents,
  resumableSession,
  sessions,
  type SessionState,
} from "./sessionRegistry.js";

/** Constant-time bearer check (mirrors wsServer's upgrade check). */
function bearerMatches(header: string | string[] | undefined): boolean {
  const h = Array.isArray(header) ? header[0] : header;
  if (!h) return false;
  const m = /^Bearer\s+(.+)$/i.exec(h.trim());
  if (!m || !m[1]) return false;
  const provided = Buffer.from(m[1]);
  const expected = Buffer.from(config.token);
  if (provided.length !== expected.length) {
    timingSafeEqual(provided, provided);
    return false;
  }
  return timingSafeEqual(provided, expected);
}

function sendJson(res: ServerResponse, status: number, body: unknown): void {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    "content-type": "application/json",
    "content-length": Buffer.byteLength(payload),
  });
  res.end(payload);
}

/** Read + JSON-parse a request body (cap at 64KB; prompts are <=8000 chars). */
async function readJsonBody(req: IncomingMessage): Promise<unknown> {
  const MAX = 64 * 1024;
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of req) {
    const buf = chunk as Buffer;
    size += buf.length;
    if (size > MAX) throw new Error("body too large");
    chunks.push(buf);
  }
  if (chunks.length === 0) return {};
  const raw = Buffer.concat(chunks).toString("utf8").trim();
  if (!raw) return {};
  return JSON.parse(raw);
}

function asString(v: unknown): string | undefined {
  return typeof v === "string" && v.length > 0 ? v : undefined;
}

/** Resolve a ProjectRef for the response (mock skips git lookups). */
async function projectRef(state: SessionState) {
  return config.mock
    ? { id: state.project.id, name: state.project.name, path: state.project.root }
    : projectRegistry.toRef(state.project);
}

/**
 * Try to handle an /api/* request. Returns true if it owned the request (and has
 * already written a response); false to let the caller fall through to other
 * handlers (/health, the 426 default).
 */
export async function handleApiRequest(
  req: IncomingMessage,
  res: ServerResponse,
): Promise<boolean> {
  let url: URL;
  try {
    url = new URL(req.url ?? "/", "http://localhost");
  } catch {
    return false;
  }
  if (!url.pathname.startsWith("/api/")) return false;

  // Auth on every /api route. A bad/missing bearer → 401 (never reveal routes).
  if (!bearerMatches(req.headers["authorization"])) {
    sendJson(res, 401, { error: "unauthorized" });
    return true;
  }

  ensureSessionSweep();
  const route = `${req.method ?? "GET"} ${url.pathname}`;

  try {
    switch (route) {
      case "POST /api/session":
        await handleSession(req, res);
        return true;
      case "POST /api/prompt":
        await handlePrompt(req, res);
        return true;
      case "GET /api/poll":
        handlePoll(url, res);
        return true;
      case "POST /api/decision":
        await handleDecision(req, res);
        return true;
      case "POST /api/mode":
        await handleMode(req, res);
        return true;
      case "POST /api/cancel":
        await handleCancel(req, res);
        return true;
      case "GET /api/projects":
        await handleProjects(res);
        return true;
      case "POST /api/select-project":
        await handleSelectProject(req, res);
        return true;
      default:
        sendJson(res, 404, { error: "not_found" });
        return true;
    }
  } catch (err) {
    if (err instanceof SyntaxError || (err as Error)?.message === "body too large") {
      sendJson(res, 400, { error: "bad_request" });
      return true;
    }
    log.error({ err, route }, "api handler error");
    sendJson(res, 500, { error: "internal" });
    return true;
  }
}

/**
 * Look up a session by id, refreshing its idle clock. Sends 410 (session_gone)
 * and returns null if unknown/expired so the client knows to re-create.
 */
function requireSession(
  sessionId: string | undefined,
  res: ServerResponse,
): SessionState | null {
  const state = sessionId ? sessions.get(sessionId) : undefined;
  if (!state) {
    sendJson(res, 410, { error: "session_gone" });
    return null;
  }
  state.lastActiveAt = Date.now();
  return state;
}

/* ───────────────────────────── routes ───────────────────────────── */

/** POST /api/session → create OR resume a socketless session. */
async function handleSession(
  req: IncomingMessage,
  res: ServerResponse,
): Promise<void> {
  const body = (await readJsonBody(req)) as Record<string, unknown>;
  const deviceId = asString(body.deviceId);
  const resumeSessionId = asString(body.resumeSessionId);

  const existing = resumableSession(resumeSessionId, deviceId);
  if (existing) {
    existing.deviceId = deviceId ?? existing.deviceId;
    existing.http = true; // now driven over HTTP
    existing.lastActiveAt = Date.now();
    sendJson(res, 200, {
      sessionId: existing.sessionId,
      mode: existing.mode,
      project: await projectRef(existing),
      models: [config.model],
      resumed: true,
      protocolVersion: PROTOCOL_VERSION,
    });
    return;
  }

  const proj = defaultProject();
  if (!proj) {
    sendJson(res, 503, { error: "no_projects" });
    return;
  }

  const state = createSession(proj, "default", {
    deviceId,
    socket: null,
    http: true,
  });
  sendJson(res, 200, {
    sessionId: state.sessionId,
    mode: state.mode,
    project: await projectRef(state),
    models: [config.model],
    resumed: false,
    protocolVersion: PROTOCOL_VERSION,
  });
}

/** POST /api/prompt → inject a prompt into the session's agent. */
async function handlePrompt(
  req: IncomingMessage,
  res: ServerResponse,
): Promise<void> {
  const body = (await readJsonBody(req)) as Record<string, unknown>;
  const state = requireSession(asString(body.sessionId), res);
  if (!state) return;
  const text = asString(body.text);
  if (!text) {
    sendJson(res, 400, { error: "missing_text" });
    return;
  }
  // Fire the turn; events stream into the session's event log asynchronously.
  void state.agent.start(text);
  sendJson(res, 202, { ok: true });
}

/** GET /api/poll?sessionId=X&cursor=N → buffered events with index >= N. */
function handlePoll(url: URL, res: ServerResponse): void {
  const state = requireSession(
    url.searchParams.get("sessionId") ?? undefined,
    res,
  );
  if (!state) return;
  const cursorParam = url.searchParams.get("cursor");
  const cursor = cursorParam ? Number.parseInt(cursorParam, 10) : 0;
  const { cursor: hi, events } = readEvents(
    state,
    Number.isFinite(cursor) && cursor >= 0 ? cursor : 0,
  );
  sendJson(res, 200, { cursor: hi, events });
}

/** POST /api/decision → resolve a parked permission request. */
async function handleDecision(
  req: IncomingMessage,
  res: ServerResponse,
): Promise<void> {
  const body = (await readJsonBody(req)) as Record<string, unknown>;
  const state = requireSession(asString(body.sessionId), res);
  if (!state) return;
  const requestId = asString(body.requestId);
  const decision = body.decision === "allow" ? "allow" : body.decision === "deny" ? "deny" : undefined;
  if (!requestId || !decision) {
    sendJson(res, 400, { error: "bad_decision" });
    return;
  }
  const note = asString(body.note);
  const ok = state.approvals.decide(requestId, { decision, note });
  if (!ok) log.debug({ requestId }, "stale permission decision (http)");
  sendJson(res, 200, { ok: true });
}

/** POST /api/mode → change permission posture mid-session. */
async function handleMode(
  req: IncomingMessage,
  res: ServerResponse,
): Promise<void> {
  const body = (await readJsonBody(req)) as Record<string, unknown>;
  const state = requireSession(asString(body.sessionId), res);
  if (!state) return;
  const mode = body.mode;
  if (
    mode !== "default" &&
    mode !== "acceptEdits" &&
    mode !== "plan" &&
    mode !== "bypassPermissions"
  ) {
    sendJson(res, 400, { error: "bad_mode" });
    return;
  }
  state.mode = mode;
  state.agent.setMode(mode);
  pushEvent(state, srv.modeChanged(mode));
  sendJson(res, 200, { ok: true });
}

/** POST /api/cancel → soft-stop the current turn. */
async function handleCancel(
  req: IncomingMessage,
  res: ServerResponse,
): Promise<void> {
  const body = (await readJsonBody(req)) as Record<string, unknown>;
  const state = requireSession(asString(body.sessionId), res);
  if (!state) return;
  await state.agent.interrupt();
  pushEvent(state, srv.status("idle"));
  pushEvent(state, srv.turnComplete("cancelled"));
  sendJson(res, 200, { ok: true });
}

/** GET /api/projects → the project registry. */
async function handleProjects(res: ServerResponse): Promise<void> {
  const projects = config.mock
    ? projectRegistry.list().map((p) => ({ id: p.id, name: p.name, path: p.root }))
    : await projectRegistry.listRefs();
  sendJson(res, 200, { projects });
}

/** POST /api/select-project → swap the session's project (new agent). */
async function handleSelectProject(
  req: IncomingMessage,
  res: ServerResponse,
): Promise<void> {
  const body = (await readJsonBody(req)) as Record<string, unknown>;
  const state = requireSession(asString(body.sessionId), res);
  if (!state) return;
  const projectId = asString(body.projectId);
  const project = projectId ? projectRegistry.get(projectId) : undefined;
  if (!project) {
    pushEvent(state, srv.notice("warn", `unknown project: ${projectId ?? ""}`));
    sendJson(res, 404, { error: "unknown_project" });
    return;
  }
  if (!config.mock && !projectRegistry.isPathAllowed(project.root)) {
    sendJson(res, 403, { error: "path_not_allowed" });
    return;
  }

  // Tear down the old agent, but keep the SAME sessionId + event log so the
  // client's poll cursor and id stay valid: swap the project + agent in place.
  await state.agent.cancel();
  attachAgent(state, project, state.mode);
  sendJson(res, 200, { ok: true });
}
