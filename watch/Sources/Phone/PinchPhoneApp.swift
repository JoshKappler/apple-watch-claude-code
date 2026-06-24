//
//  PinchPhoneApp.swift
//  @main entry point for the iPhone app. Owns the shared PinchStore and drives the
//  connection off scenePhase, mirroring the watch's foreground-driven model (an iOS app
//  with no background modes is suspended in the background too, so the socket drops and
//  resumes on return — the same lifecycle the watch already handles).
//
//  Pairing (server URL + RCE token) uses the exact same @AppStorage model as the watch:
//  baked Secrets are registered as out-of-box DEFAULTS, and anything typed in Settings
//  persists and wins.
//

import SwiftUI

@main
struct PinchPhoneApp: App {
    @StateObject private var store = PinchStore()
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("pinch.serverURL") private var serverURL = ""
    @AppStorage("pinch.token") private var token = ""
    @AppStorage("pinch.speakerMuted") private var speakerMuted = false

    init() {
        // Pre-fill pairing from the gitignored Secrets.swift so a fresh install has nothing to
        // type. register(defaults:) never clobbers a value the user typed in Settings.
        UserDefaults.standard.register(defaults: [
            "pinch.serverURL": Secrets.serverURL,
            "pinch.token": Secrets.token,
        ])
    }

    var body: some Scene {
        WindowGroup {
            RootScreen()
                .environmentObject(store)
                .tint(PinchTheme.accent)
                .onAppear {
                    store.configure(serverURL: serverURL, token: token, speakerMuted: speakerMuted)
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        store.configure(serverURL: serverURL, token: token, speakerMuted: speakerMuted)
                        store.onActive()
                    case .background:
                        store.onBackground()
                    case .inactive:
                        break
                    @unknown default:
                        break
                    }
                }
                .onChange(of: serverURL) { _, _ in reconfigureAndReconnect() }
                .onChange(of: token) { _, _ in reconfigureAndReconnect() }
                .onChange(of: speakerMuted) { _, muted in store.speaker.setMuted(muted) }
        }
    }

    private func reconfigureAndReconnect() {
        if store.configure(serverURL: serverURL, token: token, speakerMuted: speakerMuted) {
            store.onActive()
        }
    }
}
