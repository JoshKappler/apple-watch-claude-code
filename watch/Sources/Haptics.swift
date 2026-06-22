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
    static func play(_ type: WKHapticType) {
        WKInterfaceDevice.current().play(type)
    }

    /// Agent is blocked on you — make it unmissable.
    static func permissionNeeded() { play(.notification) }

    /// A turn finished cleanly / a decision was accepted.
    static func success() { play(.success) }

    /// Something failed or a turn errored.
    static func failure() { play(.failure) }

    /// Paired with TTS so you still get feedback when audio is silent.
    static func spoken() { play(.notification) }

    /// Confirms a sent prompt / a cancel landed.
    static func click() { play(.click) }

    /// Wrist-shake cancel landed.
    static func cancelled() { play(.directionDown) }
}
