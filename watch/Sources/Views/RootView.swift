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
    @State private var showModes = false
    @State private var showProjects = false

    var body: some View {
        NavigationStack {
            ZStack {
                ConversationScreen()

                // Permission gate overlays everything when present.
                if let req = store.pendingPermission {
                    PermissionCardView(request: req)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .zIndex(1)
                }
            }
            .animation(.snappy, value: store.pendingPermission)
            .navigationTitle("Pinch")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ConnectionBadge(state: store.connection, agent: store.agentState)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        store.listProjects()
                        showProjects = true
                    } label: {
                        Image(systemName: "folder")
                    }
                    Button { showModes = true } label: {
                        Image(systemName: store.mode.symbol)
                            .foregroundStyle(store.mode == .bypassPermissions ? .red : .primary)
                    }
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showModes) { ModeMenuView() }
            .sheet(isPresented: $showProjects) { ProjectPickerView() }
        }
    }
}

/// The transcript + fixed composer, laid out so the composer never scrolls (double-tap
/// requires the primary action to live outside a ScrollView/List).
private struct ConversationScreen: View {
    @EnvironmentObject private var store: PinchStore

    var body: some View {
        VStack(spacing: 0) {
            TranscriptView()
                .frame(maxHeight: .infinity)
            ComposerView()                 // fixed bottom bar — holds the .primaryAction Send.
        }
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

    private var color: Color {
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
