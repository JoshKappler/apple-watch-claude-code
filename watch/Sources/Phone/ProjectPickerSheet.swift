//
//  ProjectPickerSheet.swift
//  Pick which repo the focused agent operates in. A searchable list (the user has many
//  projects) — selecting one re-scopes the agent in place. Reached from the conversation
//  toolbar; not buried behind a hub like the watch.
//

import SwiftUI

struct ProjectPickerSheet: View {
    @EnvironmentObject private var store: PinchStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var filtered: [ProjectRef] {
        guard !query.isEmpty else { return store.projects }
        let q = query.lowercased()
        return store.projects.filter {
            $0.name.lowercased().contains(q) || ($0.path?.lowercased().contains(q) ?? false)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.projects.isEmpty && store.projectsLoading {
                    ProgressView("Loading projects…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if store.projects.isEmpty {
                    ContentUnavailableView("No projects",
                                           systemImage: "folder",
                                           description: Text("No repos were found under the backend's PINCH_PROJECT_ROOTS."))
                } else {
                    list
                }
            }
            .navigationTitle("Project")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search projects")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { store.listProjects() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .onAppear { if store.projects.isEmpty { store.listProjects() } }
        }
    }

    private var list: some View {
        List(filtered) { project in
            Button {
                store.selectProject(project)
                dismiss()
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.name)
                            .font(.body)
                            .foregroundStyle(.primary)
                        if let subtitle = subtitle(for: project) {
                            Text(subtitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if store.currentProject?.id == project.id {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(PinchTheme.accent)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .listStyle(.plain)
    }

    private func subtitle(for project: ProjectRef) -> String? {
        var parts: [String] = []
        if let branch = project.branch, !branch.isEmpty { parts.append(branch) }
        if project.dirty == true { parts.append("• uncommitted") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
