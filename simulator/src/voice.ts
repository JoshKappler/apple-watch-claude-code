/**
 * Voice I/O for the simulator.
 *
 *  - Dictation: Web Speech API (`SpeechRecognition` / `webkitSpeechRecognition`).
 *    This mirrors the watch's push-to-talk: hold the mic, speak, release. We feed
 *    interim + final results into the compose buffer. Chrome/Edge only — Firefox
 *    and Safari don't ship the recognition half, so we feature-detect and the UI
 *    falls back to typing.
 *  - TTS readback: `speechSynthesis`, used to speak `assistant_message` blocks
 *    aloud (matching the watch's AVSpeechSynthesizer readback). Broadly supported.
 *
 * Everything is guarded so the app degrades gracefully where APIs are missing.
 */

/* ── Minimal typings for the non-standard SpeechRecognition API ─────────────── */
interface SpeechRecognitionAlternativeLike {
  transcript: string;
}
interface SpeechRecognitionResultLike {
  readonly isFinal: boolean;
  readonly length: number;
  item(i: number): SpeechRecognitionAlternativeLike;
  [i: number]: SpeechRecognitionAlternativeLike;
}
interface SpeechRecognitionResultListLike {
  readonly length: number;
  item(i: number): SpeechRecognitionResultLike;
  [i: number]: SpeechRecognitionResultLike;
}
interface SpeechRecognitionEventLike extends Event {
  readonly resultIndex: number;
  readonly results: SpeechRecognitionResultListLike;
}
interface SpeechRecognitionLike extends EventTarget {
  continuous: boolean;
  interimResults: boolean;
  lang: string;
  start(): void;
  stop(): void;
  abort(): void;
  onresult: ((ev: SpeechRecognitionEventLike) => void) | null;
  onerror: ((ev: Event) => void) | null;
  onend: ((ev: Event) => void) | null;
}
type SpeechRecognitionCtor = new () => SpeechRecognitionLike;

function getRecognitionCtor(): SpeechRecognitionCtor | null {
  const w = window as unknown as {
    SpeechRecognition?: SpeechRecognitionCtor;
    webkitSpeechRecognition?: SpeechRecognitionCtor;
  };
  return w.SpeechRecognition ?? w.webkitSpeechRecognition ?? null;
}

/* ── Dictation ──────────────────────────────────────────────────────────────── */

export class Dictation {
  private ctor: SpeechRecognitionCtor | null;
  private rec: SpeechRecognitionLike | null = null;
  private baseText = ""; // compose buffer content before this dictation began
  private listening = false;

  /** Called with the live (base + interim/final) buffer as the user speaks. */
  onUpdate: (text: string) => void = () => {};
  /** Called when recognition ends (release or error), with the settled text. */
  onEnd: (text: string) => void = () => {};

  constructor() {
    this.ctor = getRecognitionCtor();
  }

  get supported(): boolean {
    return this.ctor !== null;
  }

  get active(): boolean {
    return this.listening;
  }

  /** Begin dictating, appending onto the current compose buffer. */
  start(currentBuffer: string) {
    if (!this.ctor || this.listening) return;
    this.baseText = currentBuffer.trim().length ? currentBuffer.replace(/\s*$/, "") + " " : "";
    const rec = new this.ctor();
    rec.continuous = true;
    rec.interimResults = true;
    rec.lang = navigator.language || "en-US";

    let finalChunk = "";
    rec.onresult = (ev) => {
      let interim = "";
      for (let i = ev.resultIndex; i < ev.results.length; i++) {
        const result = ev.results[i];
        if (!result) continue;
        const alt = result[0];
        const text = alt ? alt.transcript : "";
        if (result.isFinal) finalChunk += text;
        else interim += text;
      }
      this.onUpdate(this.baseText + finalChunk + interim);
    };
    rec.onerror = () => {
      // Most errors (no-speech, aborted) are benign; just settle the buffer.
      this.settle(finalChunk);
    };
    rec.onend = () => {
      this.settle(finalChunk);
    };

    this.rec = rec;
    this.listening = true;
    try {
      rec.start();
    } catch {
      this.settle("");
    }
  }

  /** Stop dictating (mic released). */
  stop() {
    if (this.rec && this.listening) {
      try {
        this.rec.stop();
      } catch {
        /* ignore */
      }
    }
  }

  private settle(finalChunk: string) {
    if (!this.listening) return;
    this.listening = false;
    this.rec = null;
    this.onEnd((this.baseText + finalChunk).trim());
  }
}

/* ── Text-to-speech readback ──────────────────────────────────────────────────── */

export class Speaker {
  private synth: SpeechSynthesis | null;
  private _muted = false;
  /** Pulses on start/stop of an utterance so the UI can show a "speaking" state. */
  onSpeaking: (speaking: boolean) => void = () => {};

  constructor() {
    this.synth =
      typeof window !== "undefined" && "speechSynthesis" in window
        ? window.speechSynthesis
        : null;
  }

  get supported(): boolean {
    return this.synth !== null;
  }

  get muted(): boolean {
    return this._muted;
  }

  setMuted(muted: boolean) {
    this._muted = muted;
    if (muted) this.cancel();
  }

  speak(text: string) {
    if (!this.synth || this._muted) return;
    const trimmed = text.trim();
    if (!trimmed) return;
    const u = new SpeechSynthesisUtterance(trimmed);
    u.rate = 1.0;
    u.pitch = 1.0;
    u.onstart = () => this.onSpeaking(true);
    u.onend = () => this.onSpeaking(false);
    u.onerror = () => this.onSpeaking(false);
    try {
      this.synth.speak(u);
    } catch {
      this.onSpeaking(false);
    }
  }

  cancel() {
    if (!this.synth) return;
    try {
      this.synth.cancel();
    } catch {
      /* ignore */
    }
    this.onSpeaking(false);
  }
}
