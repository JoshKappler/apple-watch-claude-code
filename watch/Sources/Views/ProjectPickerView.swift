//
//  ProjectPickerView.swift
//  List the backend's projects and select which repo the agent operates in.
//  Selecting sends `select_project`; the server re-scopes and replies `ready`.
//

import SwiftUI

struct ProjectPickerView: View {
    @EnvironmentObject private var store: PinchStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if store.projects.isEmpty {
                HStack {
                    ProgressView()
                    Text("Loading projects…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(store.projects) { project in
                Button {
                    store.selectProject(project)
                    dismiss()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(project.name)
                                .font(.system(size: 14, weight: .medium))
                            HStack(spacing: 4) {
                                if let branch = project.branch {
                                    Label(branch, systemImage: "arrow.triangle.branch")
                                        .font(.system(size: 10))
                                        .labelStyle(.titleAndIcon)
                                }
                                if project.dirty == true {
                                    Text("• dirty")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.orange)
                                }
                            }
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if store.currentProject?.id == project.id {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.green)
                        }
                    }
                }
            }
        }
        .navigationTitle("Projects")
        .onAppear { store.listProjects() }
    }
}
