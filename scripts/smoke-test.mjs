#!/usr/bin/env node
/**
 * End-to-end protocol smoke test for the Pinch backend.
 *
 * Drives a real WebSocket session against the backend running in PINCH_MOCK mode
 * (no API key, no Agent SDK call) and asserts the full happy-path exchange:
 *   auth -> ready -> prompt -> (thinking, assistant text, tool_use) ->
 *   permission_request -> (we allow) -> assistant_message -> turn_complete.
 *
 * Uses Node's built-in global WebSocket (Node 22+/25). Zero dependencies.
 *
 *   PINCH_URL=ws://localhost:8787/ws PINCH_TOKEN=test-token node scripts/smoke-test.mjs
 */

const URL = process.env.PINCH_URL ?? "ws://localhost:8787/ws";
const TOKEN = process.env.PINCH_TOKEN ?? "test-token";
const TIMEOUT_MS = Number(process.env.PINCH_TIMEOUT ?? 20000);

const seen = new Set();
const log = [];
let passed = false;

function done(ok, why) {
  clearTimeout(timer);
  console.log("\n── event log ─────────────────────────────");
  for (const line of log) console.log("  " + line);
  console.log("──────────────────────────────────────────");
  const need = ["ready", "status", "tool_use", "permission_request", "turn_complete"];
  const missing = need.filter((t) => !seen.has(t));
  const haveText = seen.has("assistant_delta") || seen.has("assistant_message");
  if (ok && missing.length === 0 && haveText) {
    console.log("✅ SMOKE TEST PASSED — full session round-trip works.");
    process.exit(0);
  } else {
    console.log(`❌ SMOKE TEST FAILED — ${why ?? ""}`);
    if (missing.length) console.log("   missing message types:", missing.join(", "));
    if (!haveText) console.log("   never received assistant text");
    process.exit(1);
  }
}

const timer = setTimeout(() => done(false, "timed out waiting for turn_complete"), TIMEOUT_MS);

const ws = new WebSocket(URL);

ws.addEventListener("open", () => {
  log.push("→ auth");
  ws.send(JSON.stringify({ type: "auth", token: TOKEN, protocolVersion: 1, deviceId: "smoke" }));
});

ws.addEventListener("message", (ev) => {
  let msg;
  try {
    msg = JSON.parse(typeof ev.data === "string" ? ev.data : ev.data.toString());
  } catch {
    log.push("← <unparseable frame>");
    return;
  }
  seen.add(msg.type);
  const detail =
    msg.type === "assistant_delta" ? JSON.stringify(msg.text?.slice(0, 24)) :
    msg.type === "assistant_message" ? JSON.stringify(msg.text?.slice(0, 40)) :
    msg.type === "status" ? msg.state :
    msg.type === "tool_use" ? `${msg.name}: ${msg.title}` :
    msg.type === "permission_request" ? `${msg.tool} (${msg.risk}) ${msg.requestId}` :
    msg.type === "turn_complete" ? msg.stopReason :
    msg.type === "ready" ? `session=${msg.sessionId} mode=${msg.mode}` :
    "";
  log.push(`← ${msg.type}${detail ? " · " + detail : ""}`);

  if (msg.type === "ready") {
    log.push("→ prompt");
    ws.send(JSON.stringify({ type: "prompt", text: "smoke: add a comment to README" }));
  }
  if (msg.type === "permission_request") {
    log.push(`→ permission_decision allow (${msg.requestId})`);
    ws.send(JSON.stringify({ type: "permission_decision", requestId: msg.requestId, decision: "allow" }));
  }
  if (msg.type === "error" && msg.fatal) {
    done(false, "fatal error: " + msg.message);
  }
  if (msg.type === "turn_complete") {
    passed = true;
    // give a tick for a trailing status:idle, then finish
    setTimeout(() => done(true), 150);
  }
});

ws.addEventListener("error", (e) => {
  log.push("← <socket error>");
  done(false, "socket error (is the backend running in PINCH_MOCK mode?): " + (e?.message ?? e));
});

ws.addEventListener("close", (e) => {
  if (!passed) {
    log.push(`← <closed ${e.code}>`);
    done(false, `socket closed (code ${e.code}) before turn_complete`);
  }
});
