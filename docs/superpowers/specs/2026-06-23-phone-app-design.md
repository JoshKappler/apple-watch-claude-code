# Pinch for iPhone — foundation design

Date: 2026-06-23
Status: Foundation landed (compiles end-to-end; not yet run on an iOS device).

## Goal

A native iPhone client for Pinch with the same capabilities as the watch app, taking
advantage of the larger screen. It syncs to the same thing the watch does — the backend on
the Mac — and keeps the watch's UX language: hidden settings, project selector, dictation,
keyboard minimization. The watch stays the primary focus for now; this lays the foundation so
future watch work happens in congruence with the phone's shared dependencies, without breaking
the watch.

## Decisions (settled before building)

1. **Shared core, one Xcode project.** The iOS app is a second target in `watch/project.yml`,
   not a separate project and not a copied core. The networking/state brain is shared so its
   subtle invariants (poll cursor, durable outbox, resume) are maintained once.
2. **Independent clients, not a paired app.** Watch and phone are separate apps that both talk
   to the backend over the same HTTP API. The backend is the only sync point. No
   WatchConnectivity. (watchOS 11 standalone apps make pairing unnecessary, and pairing would
   add a WatchConnectivity layer for no benefit here.)
3. **Rich rendering for phone sessions; watch sessions stay plain.** Render mode is a
   per-session property set at creation. Phone-created sessions render markdown/code/diffs;
   watch-created sessions keep plain text so they remain usable on the wrist. Default is plain,
   so the watch is byte-for-byte unchanged.
4. **List-first + fleet status.** The phone root is a list of agent sessions grouped by
   project; tapping one opens its conversation. (The watch shows one session at a time.)
5. **Do not break the watch.** Every change verified against a clean watch build.

## Architecture — the shared core

`watch/Sources/` is split into three groups:

- **`Shared/`** (both targets): `Protocol`, `WSClient` (HTTP transport + durable outbox +
  resume + poll-cursor engine), `Store` (`PinchStore`), `Speaker`, `ShakeDetector`,
  `DictationIntent`, `PushRegistration`, `DeviceID` (new — lifted out of PushRegistration,
  platform-aware id prefix), `Haptics` (made cross-platform: WKInterfaceDevice on watchOS,
  UIFeedbackGenerator on iOS, same method names so `Store` is untouched), `Secrets.swift`
  (gitignored, moved here from `Sources/`).
- **`Watch/`** (watchOS only): `PinchApp`, `CrownControls`, `Dictation`, the watch `Views/`,
  `Assets.xcassets`.
- **`Phone/`** (iOS only): `PinchPhoneApp`, the phone view layer, `PinchTheme`, the from-scratch
  `Markdown` + `DiffView` renderers, `PhoneDictation`, `Assets.xcassets`.

The audit confirmed the brain ports cleanly: `WSClient` (the riskiest piece) needed zero
changes; the only blocker for sharing `Store` was the `Haptics` enum, solved by a per-platform
implementation behind the same method names. The single platform fork inside `Shared` is in
`WSClient.openSession`, which adds `render:"rich"` to the `/api/session` body via
`#if !os(watchOS)`; the watch omits the field, so its request is unchanged.

## Backend — per-session render mode (additive, backward compatible)

- New `RenderMode = "plain" | "rich"` in `packages/protocol`.
- `POST /api/session` parses an optional `render` (defensive: anything but `"rich"` → `plain`).
- Threaded through `SessionState` / `SessionDeps` / `PersistedSession`; persisted so a revived
  phone session stays rich. Old session records lacking the field load as `plain`.
- `session.ts` `systemAppend()` picks `PHONE_SYSTEM_APPEND` (markdown/code/diffs OK) vs
  `WATCH_SYSTEM_APPEND` (plain) by `render`. The two appends share the SAME final git-rule
  paragraph verbatim. The watch never sends `render`, so it is unaffected. Mock + WS paths
  untouched. `readEvents`/`pushEvent`/cursor semantics unchanged.

## Phone screens

- **Fleet (root, `RootScreen`):** agents grouped by project (`agentGroups`), tap a row to
  focus + open its conversation, swipe to end, `+` to spawn. Not-paired empty state opens
  Settings.
- **Conversation (`ConversationView`):** rich transcript + docked composer; toolbar has the
  mode menu (guarded bypass), connection dot, a context-usage bar, and a menu for project
  picker / compact / clear / reconnect / settings; permission arrives as a sheet.
- **Transcript (`TranscriptList`):** native scroll, auto-follow-to-bottom, user/assistant
  bubbles, tool chips, notices, a thinking indicator with elapsed time. Assistant bubbles
  render markdown.
- **Composer (`ComposerBar`):** multi-line `TextField` + system keyboard (its built-in
  dictation mic), an in-app live dictation mic (`PhoneDictation` / SFSpeechRecognizer), a Send
  button that morphs to Stop while a turn runs, and a keyboard-minimize control.
- **Settings (`SettingsScreen`):** pairing (SecureField token), connection + restart backend,
  model/effort pickers, permission mode, speak-replies, context controls.
- **Project picker (`ProjectPickerSheet`):** searchable list, branch/dirty subtitle, current
  selection check.
- **Permission (`PermissionSheet`):** large Allow/Deny, real diff/command rendering, remember
  toggle (hidden for high-risk), risk coloring.
- **Renderers (`Markdown`, `DiffView`):** dependency-free. Block parser (headings, lists,
  fenced code, blockquotes, rules) + inline markdown via AttributedString; fenced ```diff and
  unified diffs route to green/red `DiffView`.

## Verified

- Watch: clean build SUCCEEDS (`-scheme Pinch`, watchOS sim) — restructure did not break it.
- iOS: shared core + all phone views compile AND link (`-target PinchPhone -sdk
  iphonesimulator26.5`, signing off).
- Backend: `npm run typecheck` + `npm run build` clean; render parse confirmed (200 with/
  without/ garbage `render`).

## Environment limitation

This Mac has the iOS SDKs but not the iOS simulator runtime, so a fully *packaged* iOS build
can't complete here (actool can't device-thin the asset catalog without a runtime). The code is
verified to compile+link; running on a device/sim needs `xcodebuild -downloadPlatform iOS`
(or Xcode → Settings → Components), then `xcodegen generate` and Run the `PinchPhone` scheme.
The phone's runtime behavior has therefore not been exercised yet — it inherits the watch's
battle-tested transport/state unchanged, but the new view layer is compile-verified only.

## Follow-ups (foundation laid, not finished)

- **Real push:** `PushRegistration` is shared and wired but `register()` is a stub and the iOS
  entitlements omit `aps-environment` (signs on the personal team, same as the watch). Real
  APNs needs a paid team + key + a backend `/api/register-push` route + a notify trigger on
  `turn_complete`/`permission_request` for a backgrounded client.
- **Full per-agent live status in the Fleet list:** currently the focused agent shows a live
  badge; others show "Running". Add each session's `AgentState` to `GET /api/agents` to light
  up the whole fleet (additive; the watch doesn't use that route).
- **App icon:** the iOS `AppIcon` set is an empty placeholder; drop in a 1024 image.
- **Phone dictation polish:** `PhoneDictation` (SFSpeechRecognizer) is compile-verified but
  not run on device; tune audio-session handling once testable.
