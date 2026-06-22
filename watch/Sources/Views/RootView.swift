//
//  RootView.swift
//  Ties the screens together. The main screen is the transcript with a fixed bottom
//  composer; a connection/status indicator sits in the nav bar; toolbar buttons open
//  mode, projects, and settings. A full-screen permission card takes over when the
//  agent is waiting on an approval.
//

import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: PinchStore
    @State private var showSettings = false
    @State private var showProjects = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                ConversationScreen()

                // Permission gate overlays everything when present.
                if let req = store.pendingPermission {
                    PermissionCardView(request: req)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .zIndex(1)
                }
            }
            .animation(.snappy, value: store.pendingPermission)
            // No navigationTitle — the app name is dead weight on a tiny screen, and the
            // system clock the OS draws at the very top can't be removed by an app anyway.
            // watchOS only renders ONE leading + ONE trailing toolbar item, so the top bar is:
            //   leading  = folder (Projects) with a small connection dot riding on it
            //   trailing = gear (Settings)
            // Mode + the rest of the composer controls live in the bottom bar.
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        store.listProjects()
                        showProjects = true
                    } label: {
                        Image(systemName: "folder")
                            .overlay(alignment: .topTrailing) {
                                // Connection status dot — kept visible up top per spec.
                                Circle()
                                    .fill(ConnectionBadge.color(state: store.connection, agent: store.agentState))
                                    .frame(width: 7, height: 7)
                                    .offset(x: 5, y: -4)
                            }
                    }
                    .accessibilityLabel("Projects")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showProjects) { ProjectPickerView() }
        }
        // Orange is applied per-control (send, mic, bubbles), NOT globally — a global tint
        // turns watchOS 26's toolbar buttons into solid orange blobs. Keep nav icons neutral.
    }
}

extension Color {
    /// Claude's signature warm coral-orange. The single accent for the whole app,
    /// against the watch's black background (the Claude Code look).
    static let pinch = Color(red: 0.85, green: 0.47, blue: 0.34)   // ≈ #D9785A
}

/// The transcript + fixed composer, laid out so the composer never scrolls (double-tap
/// requires the primary action to live outside a ScrollView/List).
private struct ConversationScreen: View {
    @EnvironmentObject private var store: PinchStore

    var body: some View {
        VStack(spacing: 0) {
            // When the input is expanded it owns the whole screen above the buttons: hide the
            // transcript so the ComposerView's draft box can fill the vertical space (maxHeight
            // .infinity). Collapsed, the transcript takes the space and the box is ~1 line.
            if !store.inputOwnsCrown {
                TranscriptView()
                    .frame(maxHeight: .infinity)
            }
            ComposerView()                 // fixed bottom bar — holds the .primaryAction Send.
                .frame(maxHeight: store.inputOwnsCrown ? .infinity : nil)
        }
        .animation(.snappy, value: store.inputOwnsCrown)
        // Extend the whole stack into the bottom safe area so the button row reaches the
        // physical bottom edge (it was floating ~1/8" high when the ignore was scoped to just
        // the HStack — a nested ignoresSafeArea doesn't push past the parent VStack's layout).
        // The outer buttons' rounded outer-bottom corners keep them clear of the screen curve.
        .ignoresSafeArea(.container, edges: .bottom)
    }
}

/// Compact connection + agent-state indicator for the nav bar.
struct ConnectionBadge: View {
    let state: ConnectionState
    let agent: AgentState

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            if let label = stateLabel {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel(accessibility)
    }

    private var color: Color { ConnectionBadge.color(state: state, agent: agent) }

    /// Shared connection-color logic so the top-bar folder dot matches the badge.
    static func color(state: ConnectionState, agent: AgentState) -> Color {
        switch state {
        case .ready:
            switch agent {
            case .idle: return .green
            case .thinking, .running_tool: return .blue
            case .waiting_permission: return .orange
            case .error: return .red
            }
        case .connected, .connecting: return .yellow
        case .reconnecting: return .orange
        case .failed: return .red
        case .disconnected: return .gray
        }
    }

    private var stateLabel: String? {
        switch state {
        case .connecting: return "…"
        case .connected: return "auth"
        case .reconnecting(let n): return "retry \(n)"
        case .failed: return "offline"
        case .disconnected: return "offline"
        case .ready:
            switch agent {
            case .thinking: return "thinking"
            case .running_tool: return "running"
            case .waiting_permission: return "approve?"
            case .error: return "error"
            case .idle: return nil
            }
        }
    }

    private var accessibility: String {
        switch state {
        case .ready: return "Connected, agent \(agent.rawValue)"
        case .failed(let m): return "Connection failed: \(m)"
        default: return "Connection \(String(describing: state))"
        }
    }
}
