//
//  PermissionSheet.swift
//  Approve / deny gate for a tool the agent wants to run. On the phone this is a proper
//  bottom sheet with large Allow/Deny buttons and a real diff/command view — no crown,
//  no height-cap hacks, no risk of approving by accident mid-scroll.
//

import SwiftUI

struct PermissionSheet: View {
    @EnvironmentObject private var store: PinchStore
    let request: ServerMsg.PermissionRequest

    @State private var remember = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header

                    if let diff = request.diff, !diff.isEmpty {
                        DiffView(content: diff)
                    } else if let command = request.command, !command.isEmpty {
                        CodeBlockView(language: "sh", content: command)
                    } else if let detail = request.detail, !detail.isEmpty {
                        CodeBlockView(language: nil, content: detail)
                    }

                    if request.risk != .high {
                        Toggle("Remember for this session", isOn: $remember)
                            .tint(PinchTheme.accent)
                    } else {
                        Label("High-risk — approve once, deliberately.", systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(16)
            }
            .safeAreaInset(edge: .bottom) { buttons }
            .navigationTitle("Permission")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(true)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: riskIcon)
                    .foregroundStyle(riskColor)
                Text(request.title)
                    .font(.headline)
            }
            Text(request.tool)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var buttons: some View {
        HStack(spacing: 12) {
            Button(role: .destructive) {
                store.decline()
            } label: {
                Text("Deny").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Button {
                store.approve(remember: remember && request.risk != .high)
            } label: {
                Text("Allow").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(request.risk == .high ? .orange : PinchTheme.accent)
        }
        .padding(16)
        .background(.bar)
    }

    private var riskColor: Color {
        switch request.risk {
        case .low:    return .secondary
        case .medium: return .yellow
        case .high:   return .orange
        }
    }

    private var riskIcon: String {
        switch request.kind {
        case .command: return "terminal.fill"
        case .edit:    return "pencil"
        case .write:   return "doc.badge.plus"
        case .other:   return "questionmark.circle"
        }
    }
}
