//
//  PushRegistration.swift
//  APNs re-engagement — STUB. Wires the structure; needs your APNs key to go live.
//
//  Why: there's no background WebSocket on watchOS, so for long-running agent tasks the
//  backend can't keep the watch in the loop. The re-engagement path is an APNs *alert*
//  push ("your task needs you") that the user taps to bring Pinch foreground, where it
//  reconnects and resumes the session. This file:
//    1. Requests notification authorization + registers for remote notifications.
//    2. Captures the device token and uploads it to the backend (POST /register-push).
//    3. Handles an incoming alert by nudging the app to reconnect.
//
//  WHAT YOU MUST DO to make this real (see README):
//    • Create an APNs Auth Key (.p8) in your Apple Developer account.
//    • Have the backend store the device token and send pushes with that key.
//    • Confirm the Push Notifications capability (aps-environment) in Pinch.entitlements.
//

import Foundation
import UserNotifications
// Note: this file is shared by the watch and phone targets. It deliberately imports
// neither WatchKit nor UIKit — the only platform-specific glue (the app-delegate that
// receives the APNs token) lives in each target's app entry point and calls
// didRegister(deviceToken:) here. `register()` is a no-op stub on both platforms until a
// paid Apple team + aps-environment entitlement are in place (see SECURITY/README).

@MainActor
final class PushRegistration: NSObject, ObservableObject {

    @Published private(set) var deviceToken: String?
    @Published private(set) var authorized = false

    /// Set by the Store so an incoming push can trigger a reconnect.
    var onReengage: (() -> Void)?

    /// Where to upload the token. Derived from the configured server base URL.
    private var uploadBaseURL: URL?
    private var bearerToken: String?

    func configure(serverURL: URL?, token: String?) {
        uploadBaseURL = serverURL
        bearerToken = token
    }

    /// No-op: APNs needs the aps-environment entitlement, which free/personal Apple teams
    /// can't have. We skip notification authorization and remote-notification registration
    /// entirely (also means no permission prompt on launch). Re-enable with a paid account
    /// by restoring the body below and adding aps-environment back to Pinch.entitlements.
    func register() async {
        // Intentionally empty. See note above.
    }

    /// Called by the app delegate when APNs hands us a token.
    func didRegister(deviceToken data: Data) {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        self.deviceToken = hex
        Task { await uploadToken(hex) }
    }

    func didFailToRegister(_ error: Error) {
        // Non-fatal: the app still works in foreground; you just won't get re-engagement pushes.
        self.deviceToken = nil
    }

    /// An alert push arrived — bring the user back into a live session.
    func handleIncomingPush() {
        onReengage?()
    }

    // MARK: - Token upload (STUB endpoint — implement on the backend)

    private func uploadToken(_ token: String) async {
        guard let base = uploadBaseURL, let bearer = bearerToken else { return }
        guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return }
        // Normalize to https for the REST upload regardless of ws/wss base.
        if comps.scheme == "ws" { comps.scheme = "http" }
        if comps.scheme == "wss" || comps.scheme == nil { comps.scheme = "https" }
        var path = comps.path
        if path.hasSuffix("/") { path.removeLast() }
        comps.path = path + "/register-push"
        guard let url = comps.url else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "deviceToken": token,
            "platform": "apns",
            "deviceId": DeviceID.current,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        // Best-effort. The backend route is a STUB you implement; failures are non-fatal.
        _ = try? await URLSession.shared.data(for: req)
    }
}

extension PushRegistration: UNUserNotificationCenterDelegate {
    // Show alerts even when foreground, and treat a tap as a re-engage.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        return [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        await MainActor.run { self.handleIncomingPush() }
    }
}
