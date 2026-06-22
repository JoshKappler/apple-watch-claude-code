//
//  PermissionCardView.swift
//  The approve/decline gate. Appears full-screen when the agent is waiting on you.
//  Title is risk-colored; the diff (edits) or command (bash) renders in a crown-scrollable
//  monospace area; ✓ / ✗ buttons sit at the bottom. A prominent haptic fires on appear.
//
//  NOTE: this card is NOT a scrolling List, and it does not declare a .primaryAction —
//  approving via double-tap would be too dangerous, so approval here is an explicit tap.
//

import SwiftUI

struct PermissionCardView: View {
    let request: ServerMsg.PermissionRequest
    @EnvironmentObject private var store: PinchStore
    @State private var remember = false

    var body: some View {
        VStack(spacing: 6) {
            header

            // Diff / command / detail in a crown-scrollable monospace pane.
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if let detail = request.detail, request.diff == nil, request.command == nil {
                        Text(detail)
                            .font(.system(size: 12))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let command = request.command {
                        CodeBlock(text: command, isDiff: false)
                    }
                    if let diff = request.diff {
                        CodeBlock(text: diff, isDiff: true)
                    }
                    if request.command == nil, request.diff == nil, request.detail == nil {
                        Text("\(request.tool) wants to run.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .frame(maxHeight: .infinity)

            // "Remember for this session" — only meaningful for low/medium auto-allow convenience.
            if request.risk != .high {
                Toggle(isOn: $remember) {
                    Text("Remember this session")
                        .font(.system(size: 11))
                }
                .toggleStyle(.switch)
                .padding(.horizontal, 8)
            }

            actions
        }
        .background(riskColor.opacity(0.12))
        .onAppear { Haptics.permissionNeeded() }
    }

    private var header: some View {
        VStack(spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: kindSymbol)
                Text(request.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(riskColor)
            Text("\(request.tool) · \(request.risk.rawValue) risk")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button(role: .destructive) {
                store.decline()
            } label: {
                Label("Deny", systemImage: "xmark")
                    .labelStyle(.iconOnly)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
            }
            .buttonStyle(.bordered)
            .tint(.red)

            Button {
                store.approve(remember: remember)
            } label: {
                Label("Allow", systemImage: "checkmark")
                    .labelStyle(.iconOnly)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
            }
            .buttonStyle(.borderedProminent)
            .tint(request.risk == .high ? .orange : .green)
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
    }

    private var riskColor: Color {
        switch request.risk {
        case .low: return .green
        case .medium: return .yellow
        case .high: return .red
        }
    }

    private var kindSymbol: String {
        switch request.kind {
        case .command: return "terminal"
        case .edit: return "pencil"
        case .write: return "doc.badge.plus"
        case .other: return "questionmark.circle"
        }
    }
}

/// Monospace code/diff pane with simple per-line diff coloring.
private struct CodeBlock: View {
    let text: String
    let isDiff: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                Text(String(line))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(color(for: String(line)))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1)
            }
        }
        .padding(8)
        .background(Color.black.opacity(0.35), in: .rect(cornerRadius: 8))
    }

    private func color(for line: String) -> Color {
        guard isDiff else { return .primary }
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return .green }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return .red }
        if line.hasPrefix("@@") { return .cyan }
        return .primary
    }
}
