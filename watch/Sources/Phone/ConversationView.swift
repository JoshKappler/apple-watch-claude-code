//
//  ConversationView.swift
//  One agent's conversation: rich transcript + docked composer, with the permission gate,
//  project picker, mode control, settings, and a context-usage bar reachable from the
//  toolbar. This is the screen you land on after tapping a session in the Fleet list.
//

import SwiftUI

struct ConversationView: View {
    @EnvironmentObject private var store: PinchStore

    @State private var showSettings = false
    @State private var showProjects = false

    var body: some View {
        TranscriptList()
            .safeAreaInset(edge: .top, spacing: 0) { contextBar }
            .safeAreaInset(edge: .bottom, spacing: 0) { ComposerBar() }
            .navigationTitle(store.currentProject?.name ?? "Pinch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .sheet(item: $store.pendingPermission) { req in
                PermissionSheet(request: req)
            }
            .sheet(isPresented: $showSettings) {
                SettingsScreen()
            }
            .sheet(isPresented: $showProjects) {
                ProjectPickerSheet()
            }
    }

    // MARK: - Context usage bar

    @ViewBuilder
    private var contextBar: some View {
        if store.contextWindow > 0 {
            HStack(spacing: 8) {
                ProgressView(value: store.contextFraction)
                    .tint(contextTint)
                Text("\(Int((store.contextFraction * 100).rounded()))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .background(.bar)
        }
    }

    private var contextTint: Color {
        let f = store.contextFraction
        if f > 0.9 { return .red }
        if f > 0.75 { return .orange }
        return PinchTheme.accent
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            ConnectionDot(connection: store.connection)
        }
        ToolbarItem(placement: .topBarTrailing) {
            ModeMenu()
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button { showProjects = true; store.listProjects() } label: {
                    Label("Project…", systemImage: "folder")
                }
                Button { store.compactContext() } label: {
                    Label("Compact context", systemImage: "arrow.down.right.and.arrow.up.left")
                }
                Button(role: .destructive) { store.clearContext() } label: {
                    Label("Clear context", systemImage: "trash")
                }
                Divider()
                Button { store.reconnect() } label: {
                    Label("Reconnect", systemImage: "arrow.clockwise")
                }
                Button { showSettings = true } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }
}

// MARK: - Connection dot

struct ConnectionDot: View {
    let connection: ConnectionState
    var body: some View {
        Circle()
            .fill(PinchTheme.color(for: connection))
            .frame(width: 9, height: 9)
            .accessibilityLabel("Connection status")
    }
}

// MARK: - Mode menu (with guarded bypass)

struct ModeMenu: View {
    @EnvironmentObject private var store: PinchStore
    @State private var confirmBypass = false

    var body: some View {
        Menu {
            ForEach(PermissionMode.allCases) { m in
                Button {
                    if m == .bypassPermissions {
                        confirmBypass = true
                    } else {
                        store.setMode(m)
                    }
                } label: {
                    Label(m.label, systemImage: store.mode == m ? "checkmark" : m.symbol)
                }
            }
        } label: {
            Image(systemName: store.mode.symbol)
                .foregroundStyle(store.mode == .bypassPermissions ? Color.orange : PinchTheme.accent)
        }
        .confirmationDialog("Skip all permissions?",
                            isPresented: $confirmBypass, titleVisibility: .visible) {
            Button("Skip permissions (dangerous)", role: .destructive) {
                store.setMode(.bypassPermissions)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The agent will run commands and edit files with no further approvals.")
        }
    }
}
