//
//  ActionButtonIntent.swift
//  OPTIONAL / ADVANCED / OFF BY DEFAULT.
//
//  The physical Action button (Ultra) can launch a third-party App Intent, BUT Apple
//  gates Action-button-launchable intents behind a workout/dive/session model — you
//  can't bind the Action button to an arbitrary app action. The supported path is a
//  workout-framed intent. We DELIBERATELY do not masquerade as a workout by default
//  (it would start a real HealthKit workout session, spin GPS/heart-rate, and pollute
//  Fitness rings) — push-to-talk via the on-screen mic is the intended input.
//
//  This file is a documented EXAMPLE for power users who genuinely want the physical
//  button. It is intentionally NOT wired into the app:
//    • There is no `.appShortcuts` registration here, so nothing is exposed by default.
//    • It will not compile-affect the app; AppIntents is available on watchOS.
//
//  TO ENABLE (advanced, at your own cost):
//    1. Add the HealthKit capability + NSHealthShareUsageDescription / NSHealthUpdateUsageDescription
//       to Info.plist and the entitlements, and the `com.apple.developer.healthkit` entitlement.
//    2. Implement an actual HKWorkoutSession start in `perform()` (omitted here on purpose).
//    3. Register an `AppShortcutsProvider` so the intent is assignable to the Action button
//       in Settings → Action Button → App.
//    4. Understand this starts a real workout. That's the deal Apple offers; we don't hide it.
//
//  For everyone else: ignore this file. The mic button is the way.
//

import AppIntents
import Foundation

/// Example intent that would (if you wire up HealthKit) be assignable to the Action button.
/// As written it just brings the app forward and flags that push-to-talk should begin.
struct StartPinchDictationIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Pinch Dictation"
    static var description = IntentDescription(
        "Advanced/optional: bind the physical Action button to start a Pinch voice prompt. "
        + "Requires a workout-framed setup (see ActionButtonIntent.swift). Off by default."
    )

    // Bring the app to the foreground when run.
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        // INTENTIONALLY MINIMAL. A real Action-button binding needs an HKWorkoutSession
        // started here (and the HealthKit capability) for the system to allow it. We do
        // NOT start one by default. Power users: implement HKWorkoutSession + set a shared
        // flag (e.g. UserDefaults "pinch.autostartMic") that ComposerView reads on appear.
        UserDefaults.standard.set(true, forKey: "pinch.autostartMic")
        return .result()
    }
}

// NOTE: No AppShortcutsProvider is declared on purpose — this intent is dormant until you
// opt in by registering one and adding HealthKit. Leaving it unregistered keeps the
// Action button on its default behavior.
