//
//  DiffView.swift
//  Renders a unified diff (or any +/- line text) with green/red line coloring on a
//  monospaced surface. Used both inside Markdown (```diff fences) and by the permission
//  card, which shows the edit a tool wants to make before you approve it.
//

import SwiftUI

struct DiffView: View {
    let content: String

    private struct Line: Identifiable {
        let id: Int
        let text: String
        let kind: Kind
        enum Kind { case add, remove, hunk, meta, context }
    }

    private var lines: [Line] {
        content.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .enumerated()
            .map { idx, raw in
                Line(id: idx, text: raw, kind: classify(raw))
            }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in
                    Text(line.text.isEmpty ? " " : line.text)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(color(for: line.kind))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 1)
                        .background(background(for: line.kind))
                }
            }
            .textSelection(.enabled)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PinchTheme.codeBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func classify(_ raw: String) -> Line.Kind {
        if raw.hasPrefix("@@") { return .hunk }
        if raw.hasPrefix("+++") || raw.hasPrefix("---") || raw.hasPrefix("diff ") || raw.hasPrefix("index ") {
            return .meta
        }
        if raw.hasPrefix("+") { return .add }
        if raw.hasPrefix("-") { return .remove }
        return .context
    }

    private func color(for kind: Line.Kind) -> Color {
        switch kind {
        case .add:     return .green
        case .remove:  return .red
        case .hunk:    return .cyan
        case .meta:    return .secondary
        case .context: return .primary
        }
    }

    private func background(for kind: Line.Kind) -> Color {
        switch kind {
        case .add:    return Color.green.opacity(0.12)
        case .remove: return Color.red.opacity(0.12)
        default:      return .clear
        }
    }
}
