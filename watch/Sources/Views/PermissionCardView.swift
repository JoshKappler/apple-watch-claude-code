//
//  PermissionCardView.swift
//  The approve/decline gate. Appears full-screen when the agent is waiting on you.
//  Title is risk-colored; the diff (edits) or command (bash) renders in a finger-scrollable
//  monospace area; a prominent haptic fires on appear.
//
//  CONFIRM IS CROWN-DRIVEN. Since watchOS gives apps no crown *press*, the decision uses a
//  CrownConfirm dial: turn the crown right past the threshold to ALLOW, left to DENY (it
//  springs back if you stop short). The crown holds focus for the decision, so the diff above
//  is scrolled with a finger. Tap ✓ / ✗ remain as an explicit shortcut. High-risk requests
//  need a deliberate, larger crown throw (a higher threshold) so nothing dangerous is casual.
//

import SwiftUI

struct PermissionCardView: View {
    let request: ServerMsg.PermissionRequest
    @EnvironmentObject private var store: PinchStore
    @State private var remember = false

    var body: some View {
        VStack(spacing: 6) {
            header

            // Diff / command / detail — finger-scrollable (crown is reserved for the decision).
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

            if request.risk != .high {
                Toggle(isOn: $remember) {
                    Text("Remember this session").font(.system(size: 11))
                }
                .toggleStyle(.switch)
                .padding(.horizontal, 8)
            }

            // Crown-driven decision. High-risk demands a bigger throw.
            CrownConfirm(
                approveTitle: "Allow",
                denyTitle: "Deny",
                threshold: request.risk == .high ? 0.9 : 0.7,
                onApprove: { store.approve(remember: remember) },
                onDeny: { store.decline() }
            )
            .padding(.horizontal, 6)

            tapShortcut
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

    /// Small tap targets that mirror the crown decision, for when a tap is easier.
    private var tapShortcut: some View {
        HStack(spacing: 8) {
            Button(role: .destructive) {
                store.decline()
            } label: {
                Image(systemName: "xmark")
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
            }
            .buttonStyle(.bordered)
            .tint(.red)

            Button {
                store.approve(remember: remember)
            } label: {
                Image(systemName: "checkmark")
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
            }
            .buttonStyle(.bordered)
            .tint(request.risk == .high ? .orange : .green)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
        .accessibilityHint("Shortcut for the crown decision above")
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
