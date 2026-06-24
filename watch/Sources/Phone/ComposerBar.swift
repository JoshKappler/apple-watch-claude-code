//
//  ComposerBar.swift
//  The docked bottom input — a native multi-line text field with the system keyboard
//  (and its built-in dictation mic), an in-app live-dictation mic, a Send button that
//  morphs to Stop while a turn runs, and one-tap keyboard minimization.
//
//  Replaces the watch's pinch/crown/caret composer machinery entirely.
//

import SwiftUI

struct ComposerBar: View {
    @EnvironmentObject private var store: PinchStore
    @StateObject private var dictation = DictationController()
    @FocusState private var focused: Bool

    /// Draft text captured when dictation starts, so partial results append rather than replace.
    @State private var dictationBase = ""

    private var isWorking: Bool {
        store.thinkingActive || store.agentState == .thinking || store.agentState == .running_tool
    }

    private var canSend: Bool {
        !store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 6) {
            if dictation.isListening {
                listeningBanner
            }
            HStack(alignment: .bottom, spacing: 8) {
                micButton
                TextField("Message", text: $store.draft, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($focused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(uiColor: .secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                if isWorking { stopButton }
                sendButton
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .onAppear { wireDictation() }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button {
                    focused = false
                } label: {
                    Label("Hide keyboard", systemImage: "keyboard.chevron.compact.down")
                }
            }
        }
        .alert("Microphone access needed",
               isPresented: Binding(get: { dictation.denied }, set: { _ in })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Enable Microphone and Speech Recognition for Pinch in Settings to dictate.")
        }
    }

    // MARK: - Buttons

    private var micButton: some View {
        Button {
            if !dictation.isListening { dictationBase = store.draft }
            dictation.toggle()
        } label: {
            Image(systemName: dictation.isListening ? "stop.circle.fill" : "mic.fill")
                .font(.title3)
                .foregroundStyle(dictation.isListening ? Color.red : PinchTheme.accent)
                .frame(width: 36, height: 36)
        }
        .accessibilityLabel(dictation.isListening ? "Stop dictation" : "Dictate")
    }

    private var sendButton: some View {
        Button {
            let text = store.draft
            store.send(text)
            focused = false
        } label: {
            Image(systemName: "arrow.up.circle.fill")
                .font(.largeTitle)
                .foregroundStyle(canSend ? PinchTheme.accent : Color.secondary)
                .frame(width: 40, height: 40)
        }
        .disabled(!canSend)
        .accessibilityLabel("Send")
    }

    private var stopButton: some View {
        Button {
            store.cancel()
        } label: {
            Image(systemName: "stop.circle.fill")
                .font(.largeTitle)
                .foregroundStyle(.red)
                .frame(width: 40, height: 40)
        }
        .accessibilityLabel("Stop the agent")
    }

    private var listeningBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .foregroundStyle(.red)
                .symbolEffect(.variableColor.iterative, isActive: true)
            Text(dictation.partial.isEmpty ? "Listening…" : dictation.partial)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 8)
    }

    // MARK: - Dictation wiring

    private func wireDictation() {
        dictation.onPartial = { partial in
            store.draft = dictationBase.isEmpty ? partial : dictationBase + " " + partial
        }
        dictation.onCommit = { final in
            store.draft = dictationBase.isEmpty ? final : dictationBase + " " + final
        }
    }
}
