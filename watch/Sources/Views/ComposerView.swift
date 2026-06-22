//
//  ComposerView.swift
//  Fixed bottom bar (NOT inside a scroll view) holding the voice + send controls.
//
//  Voice in = Apple's SYSTEM DICTATION via `TextFieldLink` — the exact dictation used for
//  texting. Tap the mic → the system dictation screen opens already listening → speak → the
//  text lands in the draft. (SFSpeechRecognizer does not work on watchOS, so an in-app
//  always-on listener isn't possible; system dictation is the real, high-quality path. A
//  hardware trigger — the Ultra's Action button — can also launch dictation; see
//  ActionButtonIntent.swift.)
//
//  Send carries `.handGestureShortcut(.primaryAction)` so the hardware DOUBLE-TAP sends, on
//  Series 9 / Ultra 2+. Only ONE primary action per screen, and it must live outside a
//  ScrollView — hence this fixed bar. Tapping the draft opens the crown-cursor editor for
//  mid-message edits (CaretEditorView).
//

import SwiftUI

struct ComposerView: View {
    @EnvironmentObject private var store: PinchStore

    @State private var draft = ""
    @State private var showEditor = false

    private var connected: Bool {
        if case .ready = store.connection { return true }
        return false
    }

    private var canSend: Bool {
        connected && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isBusy: Bool {
        store.agentState == .thinking || store.agentState == .running_tool || store.agentState == .waiting_permission
    }

    var body: some View {
        VStack(spacing: 4) {
            // Draft preview — tap to open the crown-cursor editor.
            if !draft.isEmpty {
                Button { showEditor = true } label: {
                    Text(draft)
                        .font(.system(size: 12))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .transition(.opacity)
            }

            HStack(spacing: 8) {
                // Mic → Apple system dictation. Result appended to the draft.
                TextFieldLink {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 44, height: 40)
                        .background(Color.gray.opacity(0.25), in: .rect(cornerRadius: 12))
                } onSubmit: { appendDictation($0) }
                .accessibilityLabel("Dictate")

                SendButton(enabled: canSend) { sendNow() }

                Menu {
                    Button("Edit message", systemImage: "character.cursor.ibeam") { showEditor = true }
                        .disabled(draft.isEmpty)
                    if isBusy {
                        Button("Cancel turn", systemImage: "stop.circle", role: .destructive) { store.cancel() }
                    }
                    Button("Clear", role: .destructive) { draft = "" }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 30, height: 30)
                }
                .menuIndicator(.hidden)
                .frame(width: 30)
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 2)
        }
        .animation(.snappy, value: draft.isEmpty)
        .sheet(isPresented: $showEditor) {
            CaretEditorView(text: $draft, onSend: { sendNow() })
        }
    }

    private func appendDictation(_ raw: String) {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        draft = draft.isEmpty ? t : draft + " " + t
    }

    private func sendNow() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.send(text)
        draft = ""
    }
}

// MARK: - Send (double-tap primary action)

private struct SendButton: View {
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "paperplane.fill")
                .font(.system(size: 18, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 40)
        }
        .buttonStyle(.borderedProminent)
        .tint(.accentColor)
        .disabled(!enabled)
        // Hardware double-tap → Send. No-op on unsupported hardware; on-screen tap still works.
        .handGestureShortcut(.primaryAction)
        .accessibilityLabel("Send")
    }
}
