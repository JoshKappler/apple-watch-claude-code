//
//  ModeMenuView.swift
//  Pick the permission posture. Choosing `bypassPermissions` ("dangerously skip
//  permissions") shows a guarded confirmation alert before it takes effect.
//

import SwiftUI

struct ModeMenuView: View {
    @EnvironmentObject private var store: PinchStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmBypass = false

    var body: some View {
        List {
            ForEach(PermissionMode.allCases) { mode in
                Button {
                    if mode == .bypassPermissions {
                        confirmBypass = true
                    } else {
                        store.setMode(mode)
                        dismiss()
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: mode.symbol)
                            .foregroundStyle(mode == .bypassPermissions ? .red : .accentColor)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(mode.label)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(mode == .bypassPermissions ? .red : .primary)
                            Text(mode.blurb)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if store.mode == mode {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.green)
                        }
                    }
                }
            }
        }
        .navigationTitle("Mode")
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
