//
//  ShakeDetector.swift
//  Wrist-shake → cancel, via CoreMotion (no public shake event on watchOS).
//
//  Approach: stream device motion at 50 Hz, compute the magnitude of `userAcceleration`
//  (gravity already removed by the device-motion fusion), and treat a spike over ~2.5 g
//  as a shake. Debounce ~0.6s so one shake = one cancel. Foreground-only — the Store
//  starts/stops this with scenePhase.
//

import Foundation
import CoreMotion

@MainActor
final class ShakeDetector: ObservableObject {

    /// Fired (on the main actor) when a shake crosses the threshold + debounce.
    var onShake: (() -> Void)?

    private let motion = CMMotionManager()
    private let queue = OperationQueue()
    private var lastShake: Date = .distantPast

    // Tunables.
    private let thresholdG = 2.5            // userAcceleration magnitude in g.
    private let debounce: TimeInterval = 0.6

    init() {
        queue.name = "com.josh.pinch.shake"
        queue.maxConcurrentOperationCount = 1
    }

    func start() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 50.0   // 50 Hz
        motion.startDeviceMotionUpdates(to: queue) { [weak self] data, _ in
            guard let self, let a = data?.userAcceleration else { return }
            let magnitude = sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
            guard magnitude >= self.thresholdG else { return }

            let now = Date()
            // Hop to main actor for debounce + callback.
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard now.timeIntervalSince(self.lastShake) >= self.debounce else { return }
                self.lastShake = now
                self.onShake?()
            }
        }
    }

    func stop() {
        if motion.isDeviceMotionActive {
            motion.stopDeviceMotionUpdates()
        }
    }

    deinit {
        // CMMotionManager is fine to stop from deinit; not main-actor isolated.
        motion.stopDeviceMotionUpdates()
    }
}
