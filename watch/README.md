# Pinch — watchOS app

The wrist remote for Claude Code. A single-target watchOS 11 SwiftUI app that talks the
Pinch wire protocol (`packages/protocol/PROTOCOL.md`) to the backend over a WebSocket:
voice in, response read aloud, approve/decline edits by tap, full autonomy incl. a
"dangerously skip permissions" mode, over cellular.

This directory has no build artifacts checked in — the Xcode project is **generated** from
`project.yml` with [XcodeGen](https://github.com/yonik/XcodeGen). There is no npm here.

## Prerequisites

- A Mac with **Xcode 16+** (watchOS 11 SDK).
- **XcodeGen**: `brew install xcodegen`
- An **Apple Watch Series 9 / Ultra 2 or later** for the hardware double-tap "Send".
  (Older watches — including the original Ultra — run fine; you just tap Send on screen.)
- An **Apple Developer account** (needed for signing, on-device install, and APNs).

## Generate & open

```bash
cd watch
xcodegen generate          # reads project.yml → writes Pinch.xcodeproj
open Pinch.xcodeproj
```

## What you MUST do in Xcode (needs your Apple Developer account)

1. Select the **Pinch** target → **Signing & Capabilities**.
2. Set your **Team** (this is the part only you can do — it's tied to your developer account).
3. Change the **bundle identifier** from the placeholder `com.josh.pinch.watch` to one you own
   (also update `bundleIdPrefix` / `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml` if you re-generate).
4. Confirm the **Push Notifications** capability is present (it's declared in `Pinch.entitlements`).
5. Pick your watch as the run destination and **Run**.

If you change `project.yml`, re-run `xcodegen generate`. Your signing/team settings live in
the generated project; XcodeGen won't clobber the Team you set unless you also remove it from
the project — to be safe, set Team in Xcode after each regeneration, or add a
`DEVELOPMENT_TEAM`/`xcconfig` to `project.yml`.

## Pair it

On the watch, open **Settings** (gear icon) and enter:

- **Server URL** — your backend's public URL, e.g. `wss://pinch.yourdomain.com`
  (http/https/ws/wss all accepted; it's normalized to `wss` + `/ws`). For a LAN dev box on
  plain `ws://`, add an App Transport Security exception in `Info.plist`.
- **Pairing token** — the `PINCH_TOKEN` from the backend's `.env`.

It connects on launch and whenever the app comes to the foreground.

## Control map (as implemented)

The crown is the primary input; taps are the accelerator. Two hard platform facts shape this:
the crown **press** is unavailable to apps (so confirm is built from rotation), and
`SFSpeechRecognizer` doesn't work on watchOS (so voice is Apple's **system dictation**).

| Action | Control | Notes |
|---|---|---|
| **Send** prompt | Hardware **double-tap** (pinch) | `.handGestureShortcut(.primaryAction)` on the Send button. Series 9 / Ultra 2+ only, watchOS 11+. On-screen Send is the universal fallback. |
| **Talk** | **Action button** *or* tap the mic | Both call `Dictation.present` → Apple system dictation. On watchOS 11 it reopens to your last-used method, so a dictation user lands straight in the live mic. |
| **Move the cursor** | **Digital Crown** (in the editor) | Tap the draft to open `CaretEditorView`; the crown moves the caret a character at a time. Dictation inserts at the caret. |
| **Delete previous word** | **Swipe ←** (in the editor) | Right-to-left drag. The editor is a sheet (not a nav push) so it doesn't fight the system back-swipe. |
| **Scroll** transcript / diff | **Digital Crown** | ScrollViews are crown-scrollable on the main screen. |
| **Approve / Decline** | **Crown — rotate** on the permission card | `CrownConfirm`: turn right past the threshold = allow, left = deny; springs back if you stop short. High-risk needs a bigger throw. Tap ✓ / ✗ is the shortcut; diff finger-scrolls. |
| **Pick mode / project** | **Crown — rotate, pause** | `CrownPicker`: turn to highlight, dwell to commit (a ring fills); tap a row to commit instantly. |
| **Cancel** in-flight turn | **Wrist shake** | CoreMotion `userAcceleration` > ~2.5 g with 0.6 s debounce (foreground only). |
| **Mode → bypass** | mode menu | `default` / `acceptEdits` / `plan` / `bypassPermissions`; bypass ("dangerously skip permissions") needs a guarded confirm. |
| **Readback** | automatic | `assistant_message` spoken via `AVSpeechSynthesizer` **and always paired with a haptic**. Toggle in Settings. |

## Action button → dictation (one-time setup, on the watch)

The Ultra's Action button is the one programmable physical button. After installing the app:

1. Open the **Shortcuts** app — the **"Speak a message in Pinch"** App Shortcut appears automatically
   (from `PinchAppShortcuts` in `DictationIntent.swift`). Make sure it's enabled to run on the watch.
2. On the watch: **Settings → Action Button → First Press → Shortcut**, and pick that shortcut.
3. Press the orange button anytime → Pinch opens and starts dictation.

Under the hood: the button runs `StartDictationIntent` (`openAppWhenRun`), which flips `DictationRouter`;
`PinchApp` sees it (cold launch via `onAppear`, warm via `onChange`) and calls
`WKApplication.shared().visibleInterfaceController?.presentTextInputController(...)`. The direct
(non-Shortcut) Action-button slot is still gated to workout/dive intents, which is why we use the
Shortcut path.

## Caveats you should know (these are watchOS realities, not bugs)

- **Double-tap is hardware-gated.** Series 9 / Ultra 2 and later, watchOS 11+, with the
  system Double Tap setting on. The original Ultra does NOT have it. The app feature-reports
  this in Settings → Gestures and always provides the on-screen Send button.
- **TTS can be silent without AirPods.** On Apple Watch, `AVSpeechSynthesizer` often won't
  play through the built-in speaker when no Bluetooth audio route is connected. That's why
  every spoken reply also fires a haptic — you still get feedback. Connect AirPods to actually
  *hear* responses, or rely on reading + haptics.
- **No background WebSocket.** watchOS reclaims the socket when the app suspends. Pinch keeps
  the connection only in the foreground, reconnects with exponential backoff + jitter on
  return, and **resumes** the agent session via `resumeSessionId` so an in-flight turn isn't
  lost. It pings every ~25 s to stay under Cloudflare's 100 s idle cutoff.
- **APNs re-engagement is a STUB.** `PushRegistration.swift` registers for notifications and
  uploads the device token to `POST <server>/register-push`, and a tapped alert reconnects.
  To make it live you need an **APNs Auth Key (.p8)** on your developer account and the
  backend route + sender. Until then, long tasks just need the app foregrounded.
- **No always-on voice listener.** `SFSpeechRecognizer`/`AVAudioEngine` don't function on watchOS, so
  there's no in-app open mic. Voice is Apple's **system dictation** (tap mic / press Action button →
  speak → text). Fully hands-free always-listening would need the watch mic streamed to the backend for
  server-side STT — not built (offer stands if you want it).
- **No crown press.** The crown click is reserved by the system; "confirm/select" is built from crown
  *rotation* (`CrownConfirm` threshold, `CrownPicker` dwell). Taps are the fallback everywhere.
- **Extended Runtime sessions are not requested.** Apple gates them to specific use-cases. We keep waits
  short/foreground and lean on APNs. The entitlement is documented (commented) in `Pinch.entitlements`.

## File map

```
project.yml                     XcodeGen spec (one watchOS App target, watchOS 11)
Info.plist                      usage strings, WKApplication, remote-notification bg mode
Pinch.entitlements              aps-environment; commented extended-runtime entitlement
Sources/
  PinchApp.swift                @main App + WKApplicationDelegate; consumes Action-button dictation
  Store.swift                   PinchStore — state, transcript, draft, intents; owns subsystems
  Protocol.swift                Codable mirror of the v1 wire protocol
  WSClient.swift                URLSessionWebSocketTask: auth, receive loop, heartbeat, reconnect+resume
  Dictation.swift               Apple system dictation presented programmatically (the real voice path)
  DictationIntent.swift         StartDictationIntent + DictationRouter + AppShortcut (Action button)
  CrownControls.swift           CrownConfirm (rotate-to-confirm) + CrownPicker (rotate+dwell select)
  Speaker.swift                 AVSpeechSynthesizer readback + haptic pairing + mute
  ShakeDetector.swift           CoreMotion wrist-shake → cancel
  Haptics.swift                 WKInterfaceDevice haptic helpers
  PushRegistration.swift        APNs registration + token upload (STUB)
  Views/
    RootView.swift              NavigationStack, connection badge, permission overlay
    TranscriptView.swift        crown-scrollable transcript, tool chips, speaking pulse
    ComposerView.swift          fixed bottom bar: mic (dictation) + double-tap Send; draft → editor
    CaretEditorView.swift       crown-cursor editor: move caret, dictate at caret, swipe-delete word
    PermissionCardView.swift    crown-confirm approve/decline, risk color, diff/command view
    ModeMenuView.swift          crown-picker mode menu + guarded bypass confirm
    ProjectPickerView.swift     crown-picker project list
    SettingsView.swift          server URL + token + speaker toggle + double-tap readout
```
