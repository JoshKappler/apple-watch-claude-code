/**
 * The watch UI: a thin rendering layer over a transcript model.
 *
 * It does NOT know about the WebSocket. It exposes:
 *  - imperative methods the controller calls when server frames arrive
 *    (appendDelta, addAssistantMessage, addToolUse, showPermission, …)
 *  - an `intents` object of callbacks the controller wires to the client
 *    (onSend, onPermission, onSetMode, onCancel, onSelectProject, …)
 *
 * Everything is built from DOM nodes (no template framework) so the transcript
 * can stream cheaply: deltas mutate a single text node instead of re-rendering.
 */
import type {
  AgentState,
  PermissionMode,
  ProjectRef,
  Risk,
} from "@pinch/protocol";

type Decision = "allow" | "deny";

export interface UiIntents {
  onSend: (text: string) => void;
  onPermission: (requestId: string, decision: Decision, remember: boolean) => void;
  onSetMode: (mode: PermissionMode) => void;
  onCancel: () => void;
  onSelectProject: (projectId: string) => void;
  onListProjects: () => void;
  onMicStart: () => void;
  onMicStop: () => void;
  onToggleMute: () => boolean; // returns new muted state
  onSaveSettings: (url: string, token: string) => void;
}

const STATUS_LABEL: Record<AgentState, string> = {
  idle: "Idle",
  thinking: "Thinking",
  running_tool: "Running",
  waiting_permission: "Needs you",
  error: "Error",
};

const MODE_LABEL: Record<PermissionMode, string> = {
  default: "Default",
  acceptEdits: "Accept edits",
  plan: "Plan",
  bypassPermissions: "Bypass",
};

const $ = <T extends HTMLElement = HTMLElement>(sel: string, root: ParentNode = document): T => {
  const el = root.querySelector<T>(sel);
  if (!el) throw new Error(`missing element: ${sel}`);
  return el;
};

export class WatchUi {
  private intents: UiIntents;

  // Screen regions
  private screen: HTMLElement;
  private transcript: HTMLElement;
  private statusRingWrap: HTMLElement;
  private statusLabel: HTMLElement;
  private statusDetail: HTMLElement;
  private projectChip: HTMLElement;
  private modeButton: HTMLElement;
  private connDot: HTMLElement;
  private latencyEl: HTMLElement;

  // Compose
  private composeInput: HTMLTextAreaElement;
  private sendBtn: HTMLElement;
  private micBtn: HTMLElement;
  private muteBtn: HTMLElement;

  // Live streaming state
  private streamingEl: HTMLElement | null = null;
  private thinkingEl: HTMLElement | null = null;
  private toolEls = new Map<string, HTMLElement>();
  private currentMode: PermissionMode = "default";
  private autoAllowTools = new Set<string>();

  constructor(root: HTMLElement, intents: UiIntents) {
    this.intents = intents;
    this.screen = $("#screen", root);
    this.transcript = $("#transcript", root);
    this.statusRingWrap = $("#status-ring", root);
    this.statusLabel = $("#status-label", root);
    this.statusDetail = $("#status-detail", root);
    this.projectChip = $("#project-chip", root);
    this.modeButton = $("#mode-button", root);
    this.connDot = $("#conn-dot", root);
    this.latencyEl = $("#latency", root);
    this.composeInput = $<HTMLTextAreaElement>("#compose", root);
    this.sendBtn = $("#send-btn", root);
    this.micBtn = $("#mic-btn", root);
    this.muteBtn = $("#mute-btn", root);

    this.wireControls(root);
    this.setStatus("idle");
  }

  /* ── Control wiring ──────────────────────────────────────────────────────── */

  private wireControls(root: HTMLElement) {
    // Send = double-tap analogue. Also Enter (Shift+Enter = newline).
    this.sendBtn.addEventListener("click", () => this.doSend());
    this.composeInput.addEventListener("keydown", (e) => {
      if (e.key === "Enter" && !e.shiftKey) {
        e.preventDefault();
        this.doSend();
      }
    });

    // Mic = hold to dictate (pointer down/up, plus leave/cancel safety).
    const startMic = (e: Event) => {
      e.preventDefault();
      this.micBtn.classList.add("active");
      this.intents.onMicStart();
    };
    const stopMic = () => {
      if (!this.micBtn.classList.contains("active")) return;
      this.micBtn.classList.remove("active");
      this.intents.onMicStop();
    };
    this.micBtn.addEventListener("pointerdown", startMic);
    this.micBtn.addEventListener("pointerup", stopMic);
    this.micBtn.addEventListener("pointerleave", stopMic);
    this.micBtn.addEventListener("pointercancel", stopMic);

    // Mute toggle.
    this.muteBtn.addEventListener("click", () => {
      const muted = this.intents.onToggleMute();
      this.muteBtn.classList.toggle("muted", muted);
      this.muteBtn.setAttribute("aria-pressed", String(muted));
    });

    // Cancel = wrist-shake analogue.
    $("#cancel-btn", root).addEventListener("click", () => this.intents.onCancel());

    // Mode menu.
    this.modeButton.addEventListener("click", () => this.toggleModeMenu(root));
    const modeMenu = $("#mode-menu", root);
    modeMenu.addEventListener("click", (e) => {
      const target = (e.target as HTMLElement).closest<HTMLElement>("[data-mode]");
      if (!target) return;
      const mode = target.dataset.mode as PermissionMode;
      modeMenu.classList.remove("open");
      this.requestMode(mode);
    });

    // Crown = wheel/drag over the right-edge crown scrolls the active scroller.
    this.wireCrown(root);

    // Settings panel.
    const settingsBtn = $("#settings-btn", root);
    const settingsPanel = $("#settings-panel", root);
    settingsBtn.addEventListener("click", () => settingsPanel.classList.toggle("open"));
    $("#settings-close", root).addEventListener("click", () => settingsPanel.classList.remove("open"));
    $("#settings-save", root).addEventListener("click", () => {
      const url = $<HTMLInputElement>("#cfg-url", root).value.trim();
      const token = $<HTMLInputElement>("#cfg-token", root).value.trim();
      this.intents.onSaveSettings(url, token);
      settingsPanel.classList.remove("open");
    });

    // Projects: tapping the project chip lists projects.
    this.projectChip.addEventListener("click", () => {
      this.intents.onListProjects();
      $("#projects-panel", root).classList.add("open");
    });
    $("#projects-close", root).addEventListener("click", () =>
      $("#projects-panel", root).classList.remove("open"),
    );
  }

  private wireCrown(root: HTMLElement) {
    const crown = $("#crown", root);
    let spinTimer = 0;
    const scrollActive = (delta: number) => {
      // Prefer an open permission diff; otherwise the transcript.
      const diff = this.screen.querySelector<HTMLElement>(".perm-diff");
      const scroller = diff && diff.offsetParent !== null ? diff : this.transcript;
      scroller.scrollTop += delta;
      crown.classList.add("spin");
      window.clearTimeout(spinTimer);
      spinTimer = window.setTimeout(() => crown.classList.remove("spin"), 120);
    };
    crown.addEventListener("wheel", (e) => {
      e.preventDefault();
      scrollActive(e.deltaY);
    });
    // Drag the crown vertically to scroll.
    let dragging = false;
    let lastY = 0;
    crown.addEventListener("pointerdown", (e) => {
      dragging = true;
      lastY = e.clientY;
      crown.setPointerCapture(e.pointerId);
    });
    crown.addEventListener("pointermove", (e) => {
      if (!dragging) return;
      const dy = lastY - e.clientY;
      lastY = e.clientY;
      scrollActive(dy * 2.5);
    });
    const endDrag = () => {
      dragging = false;
    };
    crown.addEventListener("pointerup", endDrag);
    crown.addEventListener("pointercancel", endDrag);
    // Let the wheel also work anywhere over the screen.
    this.screen.addEventListener("wheel", (e) => {
      const diff = this.screen.querySelector<HTMLElement>(".perm-diff");
      if (diff && diff.contains(e.target as Node)) return; // diff handles its own
      this.transcript.scrollTop += e.deltaY;
    });
  }

  private doSend() {
    const text = this.composeInput.value.trim();
    if (!text) return;
    this.pinch();
    this.intents.onSend(text);
    this.composeInput.value = "";
    this.autosize();
  }

  /* ── Compose buffer (driven by dictation) ────────────────────────────────── */

  setComposeBuffer(text: string) {
    this.composeInput.value = text;
    this.autosize();
  }

  getComposeBuffer(): string {
    return this.composeInput.value;
  }

  private autosize() {
    this.composeInput.style.height = "auto";
    this.composeInput.style.height = Math.min(this.composeInput.scrollHeight, 90) + "px";
  }

  setMicSupported(supported: boolean) {
    this.micBtn.classList.toggle("disabled", !supported);
    this.micBtn.title = supported
      ? "Hold to dictate (push-to-talk)"
      : "Dictation needs Chrome/Edge (Web Speech API)";
  }

  setMuteSupported(supported: boolean) {
    this.muteBtn.classList.toggle("disabled", !supported);
  }

  /* ── Connection / status ─────────────────────────────────────────────────── */

  setConn(state: "disconnected" | "connecting" | "authenticating" | "ready") {
    this.connDot.dataset.state = state;
    this.connDot.title = state;
  }

  setLatency(ms: number) {
    this.latencyEl.textContent = `${ms}ms`;
  }

  setStatus(state: AgentState, detail?: string) {
    // The ring color/spin/pulse is entirely CSS-driven off this data-state.
    this.statusRingWrap.dataset.state = state;
    this.statusLabel.textContent = STATUS_LABEL[state];
    this.statusDetail.textContent = detail ?? "";
  }

  /* ── Mode ────────────────────────────────────────────────────────────────── */

  setMode(mode: PermissionMode) {
    this.currentMode = mode;
    this.modeButton.textContent = MODE_LABEL[mode];
    this.modeButton.dataset.mode = mode;
  }

  getMode(): PermissionMode {
    return this.currentMode;
  }

  private requestMode(mode: PermissionMode) {
    if (mode === "bypassPermissions") {
      const ok = window.confirm(
        "Dangerously skip permissions?\n\nThe agent will run every tool — edits and shell commands — WITHOUT asking. Only do this for a session you fully trust.",
      );
      if (!ok) return;
    }
    this.intents.onSetMode(mode);
  }

  private toggleModeMenu(root: HTMLElement) {
    const menu = $("#mode-menu", root);
    menu.classList.toggle("open");
  }

  /* ── Projects ────────────────────────────────────────────────────────────── */

  setProject(project?: ProjectRef) {
    if (!project) {
      this.projectChip.textContent = "No project";
      return;
    }
    const dirty = project.dirty ? " •" : "";
    const branch = project.branch ? ` ${project.branch}` : "";
    this.projectChip.innerHTML = `<span class="pc-name">${esc(project.name)}</span><span class="pc-meta">${esc(branch)}${dirty}</span>`;
  }

  renderProjects(projects: ProjectRef[]) {
    const list = $("#projects-list");
    list.innerHTML = "";
    if (!projects.length) {
      const empty = document.createElement("div");
      empty.className = "panel-empty";
      empty.textContent = "No projects reported.";
      list.appendChild(empty);
      return;
    }
    for (const p of projects) {
      const row = document.createElement("button");
      row.className = "project-row";
      row.innerHTML = `
        <span class="pr-name">${esc(p.name)}</span>
        <span class="pr-meta">${esc(p.branch ?? "")}${p.dirty ? " • dirty" : ""}</span>
        <span class="pr-path">${esc(p.path ?? "")}</span>`;
      row.addEventListener("click", () => {
        this.intents.onSelectProject(p.id);
        $("#projects-panel").classList.remove("open");
      });
      list.appendChild(row);
    }
  }

  /* ── Transcript: assistant text ──────────────────────────────────────────── */

  appendUserMessage(text: string) {
    this.endStreaming();
    const row = document.createElement("div");
    row.className = "msg user";
    row.textContent = text;
    this.transcript.appendChild(row);
    this.scrollToBottom();
  }

  appendDelta(text: string) {
    if (!this.streamingEl) {
      this.endThinking();
      this.streamingEl = document.createElement("div");
      this.streamingEl.className = "msg assistant streaming";
      this.transcript.appendChild(this.streamingEl);
    }
    this.streamingEl.textContent = (this.streamingEl.textContent ?? "") + text;
    this.scrollToBottom();
  }

  /**
   * A final assistant block. If a delta stream is in flight we solidify that
   * node with the final text; otherwise we append a fresh block. The controller
   * speaks `text` via TTS separately.
   */
  addAssistantMessage(text: string): void {
    if (this.streamingEl) {
      this.streamingEl.classList.remove("streaming");
      this.streamingEl.classList.add("spoken");
      this.streamingEl.textContent = text;
      this.streamingEl = null;
    } else {
      const row = document.createElement("div");
      row.className = "msg assistant spoken";
      row.textContent = text;
      this.transcript.appendChild(row);
    }
    this.scrollToBottom();
  }

  private endStreaming() {
    if (this.streamingEl) {
      this.streamingEl.classList.remove("streaming");
      this.streamingEl = null;
    }
  }

  /* ── Thinking ────────────────────────────────────────────────────────────── */

  appendThinking(text: string) {
    if (!this.thinkingEl) {
      this.thinkingEl = document.createElement("div");
      this.thinkingEl.className = "thinking";
      this.thinkingEl.innerHTML = `<span class="thinking-dot"></span><span class="thinking-text"></span>`;
      this.transcript.appendChild(this.thinkingEl);
    }
    const t = this.thinkingEl.querySelector(".thinking-text");
    if (t) t.textContent = ((t.textContent ?? "") + text).slice(-140);
    this.scrollToBottom();
  }

  private endThinking() {
    if (this.thinkingEl) {
      this.thinkingEl.remove();
      this.thinkingEl = null;
    }
  }

  /* ── Tool chips ──────────────────────────────────────────────────────────── */

  addToolUse(id: string, name: string, title: string, subtitle?: string) {
    this.endThinking();
    this.endStreaming();
    const chip = document.createElement("div");
    chip.className = "tool-chip pending";
    chip.dataset.tool = id;
    chip.innerHTML = `
      <span class="tool-spin"></span>
      <span class="tool-body">
        <span class="tool-title">${esc(title || name)}</span>
        ${subtitle ? `<span class="tool-sub">${esc(subtitle)}</span>` : ""}
      </span>
      <span class="tool-status">…</span>`;
    this.transcript.appendChild(chip);
    this.toolEls.set(id, chip);
    this.scrollToBottom();
  }

  resolveToolResult(id: string, ok: boolean, summary?: string) {
    const chip = this.toolEls.get(id);
    if (!chip) return;
    chip.classList.remove("pending");
    chip.classList.add(ok ? "ok" : "fail");
    const status = chip.querySelector(".tool-status");
    if (status) status.textContent = ok ? "✓" : "✗";
    if (summary) {
      const sub = chip.querySelector(".tool-sub");
      if (sub) sub.textContent = summary;
      else {
        const body = chip.querySelector(".tool-body");
        if (body) {
          const s = document.createElement("span");
          s.className = "tool-sub";
          s.textContent = summary;
          body.appendChild(s);
        }
      }
    }
    this.scrollToBottom();
  }

  /* ── Permission card ─────────────────────────────────────────────────────── */

  /** Returns true if the request was auto-decided (and a decision was emitted). */
  showPermission(req: {
    requestId: string;
    tool: string;
    title: string;
    detail?: string;
    risk: Risk;
    kind: string;
    diff?: string;
    command?: string;
  }): boolean {
    // Client-side "remember" convenience (also honored server-side per protocol).
    if (this.autoAllowTools.has(req.tool)) {
      this.intents.onPermission(req.requestId, "allow", true);
      const note = document.createElement("div");
      note.className = "msg system";
      note.textContent = `Auto-allowed ${req.tool} (remembered)`;
      this.transcript.appendChild(note);
      this.scrollToBottom();
      return true;
    }

    const card = document.createElement("div");
    card.className = `perm-card risk-${req.risk}`;
    card.dataset.req = req.requestId;

    const body = req.diff
      ? `<pre class="perm-diff">${diffHtml(req.diff)}</pre>`
      : req.command
        ? `<pre class="perm-cmd">${esc(req.command)}</pre>`
        : req.detail
          ? `<div class="perm-detail">${esc(req.detail)}</div>`
          : "";

    card.innerHTML = `
      <div class="perm-head">
        <span class="perm-tool">${esc(req.tool)}</span>
        <span class="perm-risk risk-${req.risk}">${req.risk}</span>
      </div>
      <div class="perm-title">${esc(req.title)}</div>
      ${body}
      <label class="perm-remember"><input type="checkbox" class="perm-remember-box"> Remember for ${esc(req.tool)}</label>
      <div class="perm-actions">
        <button class="perm-deny" aria-label="Deny">✗</button>
        <button class="perm-allow" aria-label="Allow">✓</button>
      </div>`;

    const remember = () => card.querySelector<HTMLInputElement>(".perm-remember-box")?.checked ?? false;
    const decide = (decision: Decision) => {
      const rem = remember();
      if (rem && decision === "allow") this.autoAllowTools.add(req.tool);
      this.intents.onPermission(req.requestId, decision, rem);
      card.classList.add(decision === "allow" ? "decided-allow" : "decided-deny");
      card.querySelectorAll("button").forEach((b) => ((b as HTMLButtonElement).disabled = true));
    };
    $(".perm-allow", card).addEventListener("click", () => decide("allow"));
    $(".perm-deny", card).addEventListener("click", () => decide("deny"));

    this.transcript.appendChild(card);
    this.scrollToBottom();
    return false;
  }

  /* ── Notices / errors ────────────────────────────────────────────────────── */

  addNotice(level: "info" | "warn", message: string) {
    const note = document.createElement("div");
    note.className = `msg notice ${level}`;
    note.textContent = message;
    this.transcript.appendChild(note);
    this.scrollToBottom();
  }

  addError(message: string, fatal?: boolean) {
    const note = document.createElement("div");
    note.className = `msg error${fatal ? " fatal" : ""}`;
    note.textContent = (fatal ? "Fatal: " : "") + message;
    this.transcript.appendChild(note);
    this.scrollToBottom();
  }

  /* ── Speaking pulse / pinch animation ────────────────────────────────────── */

  setSpeaking(speaking: boolean) {
    this.screen.classList.toggle("speaking", speaking);
  }

  /** Brief pinch animation on send. */
  private pinch() {
    this.screen.classList.remove("pinch");
    // reflow to restart the animation
    void this.screen.offsetWidth;
    this.screen.classList.add("pinch");
    window.setTimeout(() => this.screen.classList.remove("pinch"), 320);
  }

  /* ── Settings prefill ────────────────────────────────────────────────────── */

  prefillSettings(url: string, token: string) {
    $<HTMLInputElement>("#cfg-url").value = url;
    $<HTMLInputElement>("#cfg-token").value = token;
  }

  private scrollToBottom() {
    // Defer so layout settles after innerHTML/textContent mutations.
    requestAnimationFrame(() => {
      this.transcript.scrollTop = this.transcript.scrollHeight;
    });
  }
}

/* ── helpers ──────────────────────────────────────────────────────────────── */

function esc(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

/** Colorize a unified diff for the mini-view. */
function diffHtml(diff: string): string {
  return diff
    .split("\n")
    .map((line) => {
      const e = esc(line);
      if (line.startsWith("+++") || line.startsWith("---") || line.startsWith("@@"))
        return `<span class="dl meta">${e}</span>`;
      if (line.startsWith("+")) return `<span class="dl add">${e}</span>`;
      if (line.startsWith("-")) return `<span class="dl del">${e}</span>`;
      return `<span class="dl ctx">${e}</span>`;
    })
    .join("\n");
}
