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

| Action | Control | Notes |
|---|---|---|
| **Send** prompt | Hardware **double-tap** (pinch) | `.handGestureShortcut(.primaryAction)` on the Send button. Series 9 / Ultra 2+ only, watchOS 11+, with Double Tap enabled in system Settings. On-screen Send button is the universal fallback. |
| **Talk** (push-to-talk) | **Hold the mic button** | `SFSpeechRecognizer` + `AVAudioEngine`, live partial transcript. Release to capture. A dictation/scribble field is the fallback. |
| **Scroll** transcript / diff | **Digital Crown** | ScrollViews are crown-scrollable. Crown *press* is system-reserved. |
| **Cancel** in-flight turn | **Wrist shake** | CoreMotion `userAcceleration` > ~2.5 g with 0.6 s debounce (foreground only). |
| **Approve / Decline** | **Tap** ✓ / ✗ on the permission card | Risk-colored; diff/command in a crown-scrollable monospace pane. Prominent haptic on appear. Deliberately NOT a double-tap action. |
| **Mode** | Toolbar → mode menu | `default` / `acceptEdits` / `plan` / `bypassPermissions`. Entering bypass ("dangerously skip permissions") requires a guarded confirm. |
| **Projects** | Toolbar → folder | Lists backend projects; tap to `select_project`. |
| **Readback** | automatic | `assistant_message` is spoken via `AVSpeechSynthesizer` **and always paired with a haptic**. Toggle speech in Settings. |

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
- **Extended Runtime sessions are not requested.** Apple gates them to specific use-cases.
  We keep waits short/foreground and lean on APNs. The entitlement is documented (commented)
  in `Pinch.entitlements` if you ever have a real justification.
- **Action button is optional/off.** `ActionButtonIntent.swift` is a documented example only.
  Binding the physical Action button requires a workout-framed App Intent (Apple's gate); we
  don't masquerade as a workout by default. The mic button is the intended voice input.

## File map

```
project.yml                     XcodeGen spec (one watchOS App target, watchOS 11)
Info.plist                      usage strings, WKApplication, remote-notification bg mode
Pinch.entitlements              aps-environment; commented extended-runtime entitlement
Sources/
  PinchApp.swift                @main App + WKApplicationDelegate (APNs token bridge)
  Store.swift                   PinchStore — state, transcript, intents; owns subsystems
  Protocol.swift                Codable mirror of the v1 wire protocol
  WSClient.swift                URLSessionWebSocketTask: auth, receive loop, heartbeat, reconnect+resume
  Speech.swift                  push-to-talk SFSpeechRecognizer + AVAudioEngine
  Speaker.swift                 AVSpeechSynthesizer readback + haptic pairing + mute
  ShakeDetector.swift           CoreMotion wrist-shake → cancel
  Haptics.swift                 WKInterfaceDevice haptic helpers
  PushRegistration.swift        APNs registration + token upload (STUB)
  ActionButtonIntent.swift      optional/off-by-default Action-button example
  Views/
    RootView.swift              NavigationStack, connection badge, permission overlay
    TranscriptView.swift        crown-scrollable transcript, tool chips, speaking pulse
    ComposerView.swift          fixed bottom bar: mic + double-tap Send + dictation fallback
    PermissionCardView.swift    approve/decline card, risk color, diff/command view
    ModeMenuView.swift          mode picker + guarded bypass confirm
    ProjectPickerView.swift     project list + select
    SettingsView.swift          server URL + token + speaker toggle + double-tap readout
```
