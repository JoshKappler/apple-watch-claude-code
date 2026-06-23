//
//  Haptics.swift
//  Thin wrapper over WKInterfaceDevice haptics.
//
//  Haptics matter more than usual here: watch TTS can be silent without an audio
//  route, so every spoken message is paired with a haptic, and permission requests
//  fire a prominent one so you feel the agent waiting on you.
//

import WatchKit

enum Haptics {
    /// Crisp TAP types only for the rapid-fire UI ticks (crown detents, per-char edit, list steps,
    /// button presses). `.click`/`.start`/`.stop` are short *taps* with no alert tone. The directional
    /// (`.directionUp`/`.directionDown`) and pattern (`.notification`/`.success`/`.failure`/`.retry`)
    /// types are LOUDER and carry an audible alert "buzz" — fine for one-off events (a landed reply, a
    /// cancel) but they read as a NOTIFICATION SOUND, not a tick, so they must NOT back the high-rate
    /// crown/edit/button ticks. (Routing those through `.directionUp` is exactly the "plays the
    /// notification noise on every tick" regression.)

    static func play(_ type: WKHapticType) {
        WKInterfaceDevice.current().play(type)
    }

    /// Agent is blocked on you — make it unmissable.
    static func permissionNeeded() { play(.notification) }

    /// A turn finished cleanly / a decision was accepted.
    static func success() { play(.success) }

    /// Something failed or a turn errored.
    static func failure() { play(.failure) }

    /// A real assistant reply just landed. Prominent, and fired on EVERY reply regardless of
    /// the TTS setting — the audio readback is often silent (no Bluetooth route) or switched off,
    /// so this buzz is the reliable "Claude answered" signal. Owned by the Store, not the Speaker.
    static func response() { play(.notification) }

    /// The universal interaction tap — fired on every button press, list-picker step, and per-char
    /// caret edit. A crisp, SILENT `.click` (the canonical watchOS UI tick) so a press is felt, not
    /// heard. Never an alert pattern — those play a notification tone at this rate.
    static func click() { play(.click) }

    /// Crown scroll detent, played as you physically scroll the transcript — a `.start` tap: firmer
    /// than `.click` so the crown feels like a detented dial, but still a silent tap, NOT an alert.
    /// The caller time-throttles it (crownTickMinInterval) so a fast spin or the crown's inertial
    /// coast reads as discrete detents rather than one continuous buzz.
    static func scrollTick() { play(.start) }

    /// Wrist-shake cancel landed.
    static func cancelled() { play(.directionDown) }
}
