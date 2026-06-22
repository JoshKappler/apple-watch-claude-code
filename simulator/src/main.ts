/**
 * Entry point: wires the watch UI to the WebSocket client and voice I/O.
 *
 * The controller is the only place that knows about both halves. UI intents
 * (send/permission/mode/cancel/…) translate into `ClientMsg`s; inbound
 * `ServerMsg`s drive imperative UI updates. Settings live in localStorage.
 */
import "./styles.css";
import { PinchClient, type ConnState } from "./ws";
import { WatchUi } from "./ui";
import { Dictation, Speaker } from "./voice";
import type { PermissionMode } from "@pinch/protocol";

const LS_KEY = "pinch.sim.settings.v1";
const DEFAULT_URL = "ws://localhost:8787/ws";

interface Settings {
  url: string;
  token: string;
}

function loadSettings(): Settings {
  try {
    const raw = localStorage.getItem(LS_KEY);
    if (raw) {
      const parsed = JSON.parse(raw) as Partial<Settings>;
      return { url: parsed.url || DEFAULT_URL, token: parsed.token || "" };
    }
  } catch {
    /* ignore */
  }
  return { url: DEFAULT_URL, token: "" };
}

function saveSettings(s: Settings) {
  try {
    localStorage.setItem(LS_KEY, JSON.stringify(s));
  } catch {
    /* ignore */
  }
}

function boot() {
  const root = document.getElementById("app");
  if (!root) throw new Error("missing #app root");

  let settings = loadSettings();

  const speaker = new Speaker();
  const dictation = new Dictation();

  const client = new PinchClient({ url: settings.url, token: settings.token, deviceId: "sim" });

  const ui = new WatchUi(root, {
    onSend(text) {
      ui.appendUserMessage(text);
      const ok = client.send({ type: "prompt", text });
      if (!ok) ui.addError("Not connected — set a token in settings and connect.");
    },
    onPermission(requestId, decision, remember) {
      client.send({ type: "permission_decision", requestId, decision, remember });
    },
    onSetMode(mode: PermissionMode) {
      client.send({ type: "set_mode", mode });
    },
    onCancel() {
      client.send({ type: "cancel" });
    },
    onSelectProject(projectId) {
      client.send({ type: "select_project", projectId });
    },
    onListProjects() {
      client.send({ type: "list_projects" });
    },
    onMicStart() {
      if (!dictation.supported) {
        ui.addNotice("warn", "Dictation needs Chrome or Edge (Web Speech API). Type instead.");
        return;
      }
      dictation.start(ui.getComposeBuffer());
    },
    onMicStop() {
      dictation.stop();
    },
    onToggleMute() {
      const muted = !speaker.muted;
      speaker.setMuted(muted);
      return muted;
    },
    onSaveSettings(url, token) {
      settings = { url: url || DEFAULT_URL, token };
      saveSettings(settings);
      client.configure({ url: settings.url, token: settings.token, deviceId: "sim" });
      if (!client.getSessionId()) client.connect();
    },
  });

  // Voice → compose buffer.
  dictation.onUpdate = (text) => ui.setComposeBuffer(text);
  dictation.onEnd = (text) => ui.setComposeBuffer(text);
  speaker.onSpeaking = (speaking) => ui.setSpeaking(speaking);

  ui.setMicSupported(dictation.supported);
  ui.setMuteSupported(speaker.supported);
  ui.prefillSettings(settings.url, settings.token);

  // Connection state → UI dot.
  client.on("state", (s: ConnState) => ui.setConn(s));
  client.on("latency", (ms) => ui.setLatency(ms));
  client.on("malformed", (raw) => {
    // Protocol-invalid frame; surface quietly for debugging.
    console.warn("[pinch] dropped malformed frame:", raw.slice(0, 200));
  });

  // Server frames → UI.
  client.on("message", (msg) => {
    switch (msg.type) {
      case "ready":
        ui.setMode(msg.mode);
        ui.setProject(msg.project);
        ui.addNotice("info", msg.resumed ? "Reconnected; resumed session." : "Connected.");
        break;
      case "projects":
        ui.renderProjects(msg.projects);
        break;
      case "status":
        ui.setStatus(msg.state, msg.detail);
        break;
      case "assistant_delta":
        ui.appendDelta(msg.text);
        break;
      case "assistant_message":
        ui.addAssistantMessage(msg.text);
        speaker.speak(msg.text);
        break;
      case "thinking_delta":
        ui.appendThinking(msg.text);
        break;
      case "tool_use":
        ui.addToolUse(msg.id, msg.name, msg.title, msg.subtitle);
        break;
      case "tool_result":
        ui.resolveToolResult(msg.id, msg.ok, msg.summary);
        break;
      case "permission_request":
        ui.showPermission(msg);
        break;
      case "mode_changed":
        ui.setMode(msg.mode);
        ui.addNotice("info", `Mode → ${msg.mode}`);
        break;
      case "turn_complete":
        if (msg.stopReason !== "end_turn")
          ui.addNotice("info", `Turn ended: ${msg.stopReason}`);
        break;
      case "notice":
        ui.addNotice(msg.level, msg.message);
        break;
      case "error":
        ui.addError(msg.message, msg.fatal);
        break;
      case "pong":
        // handled in client for latency
        break;
    }
  });

  // Auto-connect if we already have a token; otherwise nudge to settings.
  if (settings.token) {
    client.connect();
  } else {
    ui.addNotice("info", "Open settings (gear) to set your server URL and token.");
  }

  // Speech synthesis voices load async in some browsers; warm them.
  if (speaker.supported && "speechSynthesis" in window) {
    window.speechSynthesis.getVoices();
  }
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", boot);
} else {
  boot();
}
