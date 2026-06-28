//
//  AgentListView.swift
//  The agent switcher. Every row is a running agent — its own Claude session on the Mac, all
//  spawned at the project root. Tap one to FOCUS it (your prompts now drive that agent and its
//  conversation comes back on screen). "New agent" spawns a fresh one; swipe a row (or use the
//  trash) to remove one, which ends its backend session. The focused agent keeps a coral check.
//  You can't remove the last agent — there's always exactly one in focus.
//

import SwiftUI

struct AgentListView: View {
    @EnvironmentObject private var store: PinchStore

    var body: some View {
        // Split into typed helpers below: a single monolithic List{ForEach{Section{ForEach…}}} mixed
        // with a trailing Button makes SwiftUI's @ViewBuilder type-inference blow up ("unable to
        // type-check in reasonable time"). Each helper returns a concrete `some View` instead.
        List {
            // One SECTION per project (the header names the folder) so agents in different projects
            // are visually separated. A single project = a single section.
            ForEach(store.agentGroups) { group in
                section(for: group)
            }
            Section { newAgentButton }
        }
        .navigationTitle("Agents")
        .onAppear { Haptics.click() }   // tap feedback for landing here (moved off the hub's NavigationLink)
    }

    @ViewBuilder
    private func section(for group: AgentGroup) -> some View {
        Section {
            ForEach(group.rows) { row in
                agentRow(row)
            }
        } header: {
            Text(group.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func agentRow(_ row: AgentRowItem) -> some View {
        AgentRow(
            label: row.label,
            isFocused: row.id == store.focusedAgentId,
            focus: {
                store.focusAgent(row.id)
                // Close the ENTIRE hub sheet (not just pop back to the hub list) so the user lands
                // straight on the focused agent's conversation — one tap, no second dismiss.
                store.hubPresented = false
            }
        )
        .swipeActions(edge: .trailing) {
            // Guard the last agent — removing it would leave nothing to drive.
            if store.agents.count > 1 {
                Button(role: .destructive) {
                    store.removeAgent(row.id)
                } label: {
                    Label("Remove", systemImage: "trash")
                }
            }
        }
    }

    // Add a fresh agent and drop straight onto its clean screen.
    private var newAgentButton: some View {
        Button {
            store.createAgent()
            store.hubPresented = false   // close the whole hub sheet → land on the new agent's screen
        } label: {
            Label("New agent", systemImage: "plus.circle.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.pinch)
        }
        .buttonStyle(.plain)
    }
}

/// One agent row: a coral check when focused, then the agent's label (its auto-title — what it's
/// doing — or an "Agent N" enumerator within the project). The whole row is tappable to focus.
private struct AgentRow: View {
    let label: String
    let isFocused: Bool
    let focus: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if isFocused {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.pinch)
            }
            Text(label)
                .font(.system(size: 15, weight: isFocused ? .semibold : .regular))
                .lineLimit(1)
            Spacer(minLength: 4)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: focus)
        .accessibilityLabel(isFocused ? "\(label), focused" : label)
    }
}
