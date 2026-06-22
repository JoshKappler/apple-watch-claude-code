//
//  ComposerView.swift
//  Fixed bottom bar (NOT inside a scroll view) holding:
//    • a push-to-talk mic button (press-and-hold dictation), and
//    • the Send button, which carries `.handGestureShortcut(.primaryAction)` so the
//      hardware DOUBLE-TAP triggers it — on Series 9 / Ultra 2 and later, watchOS 11+.
//
//  Double-tap caveats handled here:
//    • Only ONE `.primaryAction` per screen → only Send gets it.
//    • The primary action must NOT live in a scrolling List/ScrollView (the system claims
//      double-tap for scrolling there) → this whole bar is fixed, outside the transcript.
//    • Unsupported hardware (Ultra 1 / older) silently ignores the shortcut; the on-screen
//      Send button still works as the fallback. We surface availability in Settings.
//
//  There's also a tiny dictation TextField fallback for when speech auth is denied.
//

import SwiftUI

struct ComposerView: View {
    @EnvironmentObject private var store: PinchStore

    /// Live composed text — fed by push-to-talk transcript or the dictation field.
    @State private var draft = ""
    @State private var showDictation = false

    private var connected: Bool {
        if case .ready = store.connection { return true }
        return false
    }

    /// Text that will actually be sent: prefer the live mic transcript while recording.
    private var outgoing: String {
        store.speech.isRecording ? store.speech.transcript : draft
    }

    private var canSend: Bool {
        connected && !outgoing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A turn is in flight — show the on-screen cancel affordance.
    private var isBusy: Bool {
        store.agentState == .thinking || store.agentState == .running_tool || store.agentState == .waiting_permission
    }

    var body: some View {
        VStack(spacing: 4) {
            // Live preview of what will be sent (mic transcript or typed draft).
            if !outgoing.isEmpty {
                Text(outgoing)
                    .font(.system(size: 12))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(store.speech.isRecording ? .primary : .secondary)
                    .padding(.horizontal, 8)
                    .transition(.opacity)
            }

            HStack(spacing: 8) {
                MicButton()
                SendButton(enabled: canSend) { sendNow() }
                Menu {
                    Button("Type instead") { showDictation = true }
                    // On-screen cancel mirrors the wrist-shake, for when shake is awkward.
                    if isBusy {
                        Button("Cancel turn", systemImage: "stop.circle", role: .destructive) {
                            store.cancel()
                        }
                    }
                    Button("Clear", role: .destructive) { clear() }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 30, height: 30)
                }
                .menuIndicator(.hidden)
                .frame(width: 30)
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 2)
        }
        .animation(.snappy, value: outgoing.isEmpty)
        // Dictation fallback: the system scribble/dictation keyboard.
        .sheet(isPresented: $showDictation) {
            DictationSheet(text: $draft) { showDictation = false; if canSend { sendNow() } }
        }
        // When recording stops, fold the captured transcript into the draft.
        .onChange(of: store.speech.isRecording) { wasRecording, isRecording in
            if wasRecording && !isRecording {
                let captured = store.speech.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                if !captured.isEmpty { draft = captured }
            }
        }
    }

    private func sendNow() {
        let text = outgoing.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.send(text)
        clear()
    }

    private func clear() {
        draft = ""
        store.speech.reset()
    }
}

// MARK: - Mic (push-to-talk hold)

private struct MicButton: View {
    @EnvironmentObject private var store: PinchStore
    @State private var holding = false

    var body: some View {
        Image(systemName: store.speech.isRecording ? "waveform" : "mic.fill")
            .font(.system(size: 18, weight: .semibold))
            .frame(width: 44, height: 40)
            .background(
                (store.speech.isRecording ? Color.red : Color.gray.opacity(0.25)),
                in: .rect(cornerRadius: 12)
            )
            .foregroundStyle(store.speech.isRecording ? .white : .primary)
            .scaleEffect(holding ? 0.92 : 1)
            // Press-and-hold: start on press, stop (and capture) on release.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !holding else { return }
                        holding = true
                        Haptics.click()
                        store.speech.start()
                    }
                    .onEnded { _ in
                        holding = false
                        _ = store.speech.stop()
                    }
            )
            .accessibilityLabel("Hold to talk")
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

// MARK: - Dictation fallback

private struct DictationSheet: View {
    @Binding var text: String
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text("Dictate or scribble")
                .font(.headline)
            // The watch presents dictation/scribble for any TextField.
            TextField("Message", text: $text)
                .lineLimit(3)
            Button("Send", action: onDone)
                .buttonStyle(.borderedProminent)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding()
    }
}
