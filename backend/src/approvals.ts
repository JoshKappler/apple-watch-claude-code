/**
 * Approval registry — the bridge between the SDK's async `canUseTool` callback
 * and the watch's `permission_decision` frame.
 *
 * When the SDK asks whether a tool may run, the session parks a Promise here
 * keyed by a fresh requestId and emits a `permission_request` to the watch. When
 * the watch taps approve/decline (or the turn is aborted), we resolve that exact
 * Promise. This is the load-bearing remote-approval round-trip.
 */
import { randomUUID } from "node:crypto";

export interface ApprovalOutcome {
  decision: "allow" | "deny";
  /** Optional note from the user (forwarded to the SDK deny message). */
  note?: string;
}

interface Pending {
  resolve: (outcome: ApprovalOutcome) => void;
}

export class ApprovalRegistry {
  private readonly pending = new Map<string, Pending>();

  /**
   * Park a new approval and return its requestId + a Promise that settles when
   * `decide()` is called (or `cancelAll()` runs). Never rejects — an aborted or
   * dropped approval resolves to a "deny" so the SDK callback always returns.
   */
  create(): { requestId: string; wait: Promise<ApprovalOutcome> } {
    const requestId = `p_${randomUUID().slice(0, 8)}`;
    const wait = new Promise<ApprovalOutcome>((resolve) => {
      this.pending.set(requestId, { resolve });
    });
    return { requestId, wait };
  }

  /** Resolve a parked approval from a client decision. No-op if unknown/stale. */
  decide(requestId: string, outcome: ApprovalOutcome): boolean {
    const p = this.pending.get(requestId);
    if (!p) return false;
    this.pending.delete(requestId);
    p.resolve(outcome);
    return true;
  }

  /** True if this requestId is still awaiting a decision. */
  has(requestId: string): boolean {
    return this.pending.has(requestId);
  }

  /** Auto-deny every parked approval (used on cancel / disconnect / abort). */
  cancelAll(note = "cancelled"): void {
    for (const [, p] of this.pending) p.resolve({ decision: "deny", note });
    this.pending.clear();
  }
}
