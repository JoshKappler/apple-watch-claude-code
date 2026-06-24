//
//  RootScreen.swift
//  The app root: a Fleet list of agent sessions grouped by project. Tapping a row focuses
//  that agent and pushes its Conversation; "+" spawns a new agent. This is the thing the
//  watch fundamentally can't do — every session visible at once on one screen.
//
//  Note: the Store tracks the live agentState of the FOCUSED agent only (the watch parks
//  the others). So the focused row shows a live badge; other rows show that they're running.
//  Full per-agent live badges across the fleet need a small backend addition (agent state in
//  GET /api/agents) — see the design doc; the UI here is ready for it.
//

import SwiftUI

struct RootScreen: View {
    @EnvironmentObject private var store: PinchStore
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.canConnect {
                    fleetList
                } else {
                    NotPairedView()
                }
            }
            .navigationTitle("Agents")
            .toolbar { toolbar }
            .navigationDestination(for: String.self) { _ in
                ConversationView()
            }
        }
    }

    private var fleetList: some View {
        List {
            ConnectionHeader(connection: store.connection)
            ForEach(store.agentGroups) { group in
                Section(group.name) {
                    ForEach(group.rows) { row in
                        Button {
                            open(row.id)
                        } label: {
                            FleetRow(
                                label: row.label,
                                isFocused: row.id == store.focusedAgentId,
                                state: store.agentState
                            )
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            if store.agents.count > 1 {
                                Button(role: .destructive) {
                                    store.removeAgent(row.id)
                                } label: {
                                    Label("End", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                store.createAgent()
                path.append(store.focusedAgentId)
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("New agent")
        }
    }

    private func open(_ id: String) {
        store.focusAgent(id)
        path.append(id)
    }
}

// MARK: - Rows

private struct FleetRow: View {
    let label: String
    let isFocused: Bool
    let state: AgentState

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(isFocused ? PinchTheme.color(for: state) : Color.secondary.opacity(0.4))
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.body)
                    .foregroundStyle(.primary)
                Text(isFocused ? PinchTheme.label(for: state) : "Running")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }
}

private struct ConnectionHeader: View {
    let connection: ConnectionState
    var body: some View {
        HStack(spacing: 8) {
            ConnectionDot(connection: connection)
            Text(statusText)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .listRowBackground(Color.clear)
    }

    private var statusText: String {
        switch connection {
        case .connected, .ready: return "Connected"
        case .connecting:        return "Connecting…"
        case .reconnecting:      return "Reconnecting…"
        case .disconnected:      return "Offline"
        case .failed(let m):     return m
        }
    }
}

private struct NotPairedView: View {
    @State private var showSettings = false
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "link.badge.plus")
                .font(.largeTitle)
                .foregroundStyle(PinchTheme.accent)
            Text("Not paired")
                .font(.headline)
            Text("Set your backend URL and token in Settings to connect.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Open Settings") { showSettings = true }
                .buttonStyle(.borderedProminent)
                .tint(PinchTheme.accent)
        }
        .padding(32)
        .sheet(isPresented: $showSettings) { SettingsScreen() }
    }
}
