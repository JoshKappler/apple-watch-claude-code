# Watch question/answer interface — design

**Date:** 2026-06-22
**Status:** Step 1 implemented. **Step 2 is DEFERRED — this doc is the handoff note for a future agent.**

## Problem

Every "question" the agent puts to the user on the watch currently arrives in one of two shapes,
and neither is good:

1. **Permission requests** (`permission_request` frame) rendered as a **full-screen takeover**
   (`PermissionCardView`). The decision used to be **crown-driven** (`CrownConfirm`): turning the
   Digital Crown past a threshold approved/denied. Two failures:
   - A request appears while you're crown-scrolling the chat → the in-flight crown turn
     **approves/denies by accident**. Dangerous, especially for the high-risk asks.
   - The takeover **hides the chat**, so you can't scroll back to see the context that led to the
     request.
2. **The agent's structured-question tool (`AskUserQuestion`) does not work on the watch at all.**
   The backend doesn't handle it specially, so it falls through the `canUseTool` permission gate
   and there is no watch UI that can return a *choice*. In practice it **auto-fails/rejects** — the
   user sees a question they cannot answer.
3. Free-form (prose) questions work fine: the agent emits `assistant_message`, the user dictates a
   reply via the normal `prompt` flow. This is the universal fallback.

## The reframe (the key idea)

You do **not** need a screen per question format. Every question the agent can ask collapses into
**one of three answer shapes**:

1. **Pick one** — yes/no, allow/deny, approve/reject a plan, "A / B / C" are all this (N options).
2. **Pick several** — multi-select.
3. **Say something** — open-ended; already handled by the mic/compose bar.

So the watch needs **one adaptive answer bar** with those three modes, and every question *source*
(permission request, `AskUserQuestion`, `ExitPlanMode`, prose) is normalized onto it. A permission
request is just "pick one of {Allow, Deny}" with a diff to inspect and a remember toggle.

## Design principle

Questions become **non-blocking, bottom-docked answer bars**. The chat stays **visible and
crown-scrollable above** them; the answer bar is **never crown-focusable**, so the crown only ever
scrolls the chat — a popup can never hijack your scroll or answer itself. Answers are always
**explicit taps** (or dictation for free-form).

---

## Step 1 — non-blocking permission bar  ✅ IMPLEMENTED (2026-06-22)

Watch-only; **no protocol or backend changes**.

- The permission decision is **tap-only** (Allow / Deny buttons). `CrownConfirm` is deleted (done in
  an earlier commit on 2026-06-22). The crown does nothing on the decision.
- `PermissionCardView` is no longer a full-screen takeover. It is a **bottom bar** that replaces the
  composer slot while the agent is waiting. The transcript fills the space above it and stays
  crown-scrollable (it is not focusable, so with no crown-focused view the crown scrolls it by
  default).
- Layout lives in `RootView.ConversationScreen`: when `store.pendingPermission != nil`, show
  `TranscriptView` (flex, top) + the permission bar (intrinsic height, bottom). The bar's diff/
  command area is a finger-scrollable `ScrollView` **capped** (≈ maxHeight) so the bar never grows
  past ~⅔ of the screen and starves the transcript.
- Files: `watch/Sources/Views/RootView.swift`, `watch/Sources/Views/PermissionCardView.swift`,
  `watch/Sources/CrownControls.swift` (CrownConfirm removed).

---

## Step 2 — structured questions  ⛔ DEFERRED (build this next)

Goal: make `AskUserQuestion` (and plan approval via `ExitPlanMode`) **answerable on the watch** via
the same non-blocking adaptive bar — pick-one and pick-several modes — and feed the choice back to
the agent.

### Backend architecture (as of 2026-06-22, for grounding)

- The backend drives Claude Code via the **Claude Agent SDK** (`@anthropic-ai/claude-agent-sdk`),
  `query({ prompt, options })` in streaming-input mode. Entry: `backend/src/index.ts`; session
  wrapper: `backend/src/session.ts` (`ClaudeSession.start`, `consume`, `handleMessage`).
- **Permission gate:** `session.ts` `makeCanUseTool()` (wired as `options.canUseTool`, skipped when
  `mode === "bypassPermissions"`). It parks a Promise via `ApprovalRegistry` (`approvals.ts`), emits
  `srv.permissionRequest(...)`, and races the watch's decision against the abort signal. **An
  "allow" MUST include `updatedInput`** or the SDK runs the tool with empty input.
- Decision return path: `connection.ts` `handlePermissionDecision` → `approvals.decide(requestId, …)`
  resolves the parked Promise. `remember:true` adds the tool to `rememberedTools` for the session.
- `AskUserQuestion` / `ExitPlanMode` are **not** handled specially today (grep confirms). They fall
  through `canUseTool` as generic tools.
- Protocol: `packages/protocol/src/index.ts` (Zod, source of truth) mirrored by
  `watch/Sources/Protocol.swift` (keep in sync by hand). Build `@pinch/protocol` dist before the
  backend sees new symbols (`npm run build --workspace packages/protocol`).

### Proposed implementation

1. **Protocol** — add two frames (TS + Swift mirror):
   - server→client `question`: `{ questionId, prompt, options: [{ id, label, detail? }], multi: bool,
     source: "ask"|"plan" }`
   - client→server `question_response`: `{ questionId, selectedOptionIds: string[] }`
2. **Backend** — in `makeCanUseTool` (or a dedicated pre-gate), intercept `toolName === "AskUserQuestion"`
   and `"ExitPlanMode"`:
   - Parse the SDK tool `input` into `{ prompt, options[], multi }`. (Inspect the real shape the SDK
     passes for these tools — `AskUserQuestion` carries one or more questions, each with options;
     decide whether to flatten to one question or support a small queue.)
   - Park a Promise in a new `QuestionRegistry` (sibling of `ApprovalRegistry`), emit the `question`
     frame, race against abort.
   - On `question_response`, resolve and return `{ behavior: "allow", updatedInput: <the structured
     answer the tool expects> }`. For `ExitPlanMode`, map approve→allow, reject→deny.
3. **Watch** — promote the Step 1 bottom bar into the **adaptive answer bar**:
   - pick-one → a button per option (binary keeps red/green).
   - pick-several → checkable rows + a Confirm button.
   - The question prompt text shows in the bar (or as a chat card); the chat stays scrollable above.
   - Add `store.pendingQuestion` alongside `pendingPermission`; send `question_response`.
4. **Agent behavior** — once this works, prefer `AskUserQuestion` for choices when watch-driven.
   Until then, **ask choices as prose with numbered options** so the user can answer by dictation.

### Risks / unknowns for the next agent

- The exact `input`/`updatedInput` schema the SDK uses for `AskUserQuestion` and `ExitPlanMode` —
  verify against a live SDK run before coding the parse/return.
- `AskUserQuestion` can carry multiple questions at once; decide single-vs-queue.
- Keep the abort/cancel path (shake-to-cancel, `cancelAll`) resolving pending questions so the agent
  callback never hangs.

## Out of scope

- No change to the 8000-char `prompt` input cap (generous; not the dictation issue).
- Free-form questions keep using the existing prose → `prompt` flow.
