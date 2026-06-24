//
//  Haptics.swift
//  Cross-platform haptic facade — one API, a per-platform implementation.
//
//  The public method names (click/scrollTick/success/failure/response/permissionNeeded/
//  cancelled) are the SHARED contract that Store.swift calls; the bodies below are
//  selected by platform. Keeping the names stable is what lets Store.swift live in the
//  shared core unchanged.
//
//  watchOS: WKInterfaceDevice taps. Haptics matter more there — watch TTS can be silent
//  without an audio route, so a landed reply / a waiting permission is signalled by a
//  prominent buzz. The crisp `.click`/`.start` TAP types back the high-rate UI ticks
//  (crown detents, per-char edit, button presses); the louder pattern types
//  (`.notification`/`.success`/`.failure`) are reserved for one-off events — routing the
//  high-rate ticks through the loud types is the "notification noise on every tick"
//  regression, so don't.
//
//  iOS: UIFeedbackGenerator. The phone has a screen and a speaker, so haptics are a
//  lighter accent rather than the primary channel — selection ticks for UI taps,
//  notification feedback for success/failure/permission.
//

#if os(watchOS)
import WatchKit

enum Haptics {
    /// watch-only escape hatch for a raw tap type.
    static func play(_ type: WKHapticType) {
        WKInterfaceDevice.current().play(type)
    }

    /// Agent is blocked on you — make it unmissable.
    static func permissionNeeded() { play(.notification) }

    /// A turn finished cleanly / a decision was accepted.
    static func success() { play(.success) }

    /// Something failed or a turn errored.
    static func failure() { play(.failure) }

    /// A real assistant reply just landed. Prominent, and fired on EVERY reply regardless
    /// of the TTS setting — the audio readback is often silent (no Bluetooth route) or off,
    /// so this buzz is the reliable "Claude answered" signal. Owned by the Store.
    static func response() { play(.notification) }

    /// The universal interaction tap — button presses, list-picker steps, per-char edits.
    /// A crisp, SILENT `.click`; never an alert pattern at this rate.
    static func click() { play(.click) }

    /// Crown scroll detent — a firmer-but-silent `.start` tap. The caller time-throttles it.
    static func scrollTick() { play(.start) }

    /// Wrist-shake cancel landed.
    static func cancelled() { play(.directionDown) }
}

#else
import UIKit

enum Haptics {
    /// Agent is blocked on you — a warning notification feel.
    static func permissionNeeded() { notify(.warning) }

    /// A turn finished cleanly / a decision was accepted.
    static func success() { notify(.success) }

    /// Something failed or a turn errored.
    static func failure() { notify(.error) }

    /// A real assistant reply just landed — a gentle tap (you also SEE it on a phone).
    static func response() { impact(.light) }

    /// The universal interaction tap — button presses, row selection.
    static func click() { selection() }

    /// Scroll detent — on a phone scrolling is native, so this is a quiet selection tick.
    static func scrollTick() { selection() }

    /// Cancel landed.
    static func cancelled() { impact(.rigid) }

    // MARK: - UIKit generators (must run on the main thread; all callers are @MainActor)

    private static func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        let g = UINotificationFeedbackGenerator()
        g.prepare()
        g.notificationOccurred(type)
    }

    private static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let g = UIImpactFeedbackGenerator(style: style)
        g.prepare()
        g.impactOccurred()
    }

    private static func selection() {
        let g = UISelectionFeedbackGenerator()
        g.prepare()
        g.selectionChanged()
    }
}
#endif
