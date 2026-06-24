//
//  ModeMenuView.swift
//  Pick the permission posture with the crown: turn to highlight a mode, pause to commit
//  (CrownPicker), or tap a row. Choosing `bypassPermissions` ("dangerously skip permissions")
//  always routes through a guarded confirmation first — the dwell/tap only *proposes* it.
//

import SwiftUI

struct ModeMenuView: View {
    @EnvironmentObject private var store: PinchStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmBypass = false

    private var modes: [PermissionMode] { PermissionMode.allCases }

    var body: some View {
        VStack(spacing: 6) {
            Text("Mode · turn crown, pause to pick")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            CrownPicker(
                items: modes,
                title: { $0.label },
                subtitle: { $0.blurb },
                initialIndex: modes.firstIndex(of: store.mode) ?? 0,
                onCommit: { mode in
                    if mode == .bypassPermissions {
                        confirmBypass = true        // guarded — don't apply yet
                    } else {
                        store.setMode(mode)
                        dismiss()
                    }
                }
            )
        }
        .alert("Skip all permissions?", isPresented: $confirmBypass) {
            Button("Cancel", role: .cancel) { }
            Button("Skip permissions", role: .destructive) {
                store.setMode(.bypassPermissions)
                Haptics.failure()   // deliberately alarming feedback.
                dismiss()
            }
        } message: {
            Text("The agent will run edits and commands with NO approvals. It can modify and delete files and run shell commands unattended. Only do this when you trust the task.")
        }
    }
}
