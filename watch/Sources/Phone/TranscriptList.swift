//
//  TranscriptList.swift
//  The scrolling conversation feed for the phone — native finger scroll, rich rendering,
//  auto-follow-to-bottom. Replaces the watch's crown-driven, scroll-disabled transcript;
//  none of that machinery is needed here.
//

import SwiftUI

struct TranscriptList: View {
    @EnvironmentObject private var store: PinchStore

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if store.transcript.isEmpty && !showThinking {
                        EmptyConversation()
                            .padding(.top, 60)
                    }
                    ForEach(store.transcript) { item in
                        TranscriptRow(item: item)
                            .id(item.id)
                    }
                    if showThinking {
                        ThinkingIndicator(startedAt: store.turnStartedAt, state: store.agentState)
                            .id("thinking")
                    }
                    Color.clear.frame(height: 1).id(bottomAnchor)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: store.transcript.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: lastAssistantText) { _, _ in scrollToBottom(proxy) }
            .onChange(of: store.thinkingActive) { _, _ in scrollToBottom(proxy) }
            .onAppear { scrollToBottom(proxy, animated: false) }
        }
    }

    private let bottomAnchor = "BOTTOM_ANCHOR"

    private var showThinking: Bool {
        store.thinkingActive || store.agentState == .thinking || store.agentState == .running_tool
    }

    /// Tracks the streaming assistant bubble so deltas keep the view pinned to the bottom.
    private var lastAssistantText: String {
        for item in store.transcript.reversed() {
            if case let .assistant(_, text) = item { return text }
        }
        return ""
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        if animated {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
        } else {
            proxy.scrollTo(bottomAnchor, anchor: .bottom)
        }
    }
}

// MARK: - Rows

private struct TranscriptRow: View {
    let item: TranscriptItem

    var body: some View {
        switch item {
        case let .user(_, text, delivery):
            UserBubble(text: text, delivery: delivery)
        case let .assistant(_, text):
            AssistantBubble(text: text)
        case let .tool(use, ok):
            ToolChip(use: use, ok: ok)
        case let .notice(_, text, warn):
            NoticeRow(text: text, warn: warn)
        }
    }
}

private struct UserBubble: View {
    let text: String
    let delivery: TranscriptItem.Delivery

    var body: some View {
        HStack {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 2) {
                Text(text)
                    .foregroundStyle(PinchTheme.userBubbleText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(PinchTheme.userBubble)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .textSelection(.enabled)
                deliveryGlyph
            }
        }
    }

    @ViewBuilder
    private var deliveryGlyph: some View {
        switch delivery {
        case .sending:
            Label("Sending", systemImage: "clock")
                .labelStyle(.iconOnly)
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .sent:
            Image(systemName: "checkmark")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .failed:
            Label("Not sent", systemImage: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.red)
        }
    }
}

private struct AssistantBubble: View {
    let text: String

    var body: some View {
        HStack {
            MarkdownView(text: text)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(PinchTheme.assistantBubble)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            Spacer(minLength: 28)
        }
    }
}

private struct ToolChip: View {
    let use: ServerMsg.ToolUse
    let ok: Bool?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(use.title.isEmpty ? use.name : use.title)
                    .font(.footnote.weight(.medium))
                if let sub = use.subtitle, !sub.isEmpty {
                    Text(sub)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(uiColor: .tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var icon: String {
        switch ok {
        case .some(true):  return "checkmark.circle.fill"
        case .some(false): return "xmark.circle.fill"
        case .none:        return "wrench.and.screwdriver.fill"
        }
    }
    private var tint: Color {
        switch ok {
        case .some(true):  return .green
        case .some(false): return .red
        case .none:        return .secondary
        }
    }
}

private struct NoticeRow: View {
    let text: String
    let warn: Bool

    var body: some View {
        HStack {
            Spacer()
            Label(text, systemImage: warn ? "exclamationmark.triangle" : "info.circle")
                .font(.caption)
                .foregroundStyle(warn ? .orange : .secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
    }
}

// MARK: - Thinking indicator + empty state

private struct ThinkingIndicator: View {
    let startedAt: Date?
    let state: AgentState

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(label)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let startedAt {
                Text(timerText(since: startedAt))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private var label: String {
        switch state {
        case .running_tool: return "Working…"
        case .waiting_permission: return "Waiting on you…"
        default: return "Thinking…"
        }
    }

    private func timerText(since: Date) -> String {
        // A coarse, allocation-free elapsed label; the view re-renders as state changes.
        let elapsed = Int(max(0, Date().timeIntervalSince(since)))
        let m = elapsed / 60, s = elapsed % 60
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }
}

private struct EmptyConversation: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.bubble")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("Send a message to start.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
