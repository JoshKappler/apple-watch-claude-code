//
//  ComposerView.swift
//  Fixed bottom bar (NOT inside a scroll view) holding the voice + send + navigation controls.
//
//  Voice in = Apple's SYSTEM DICTATION, presented programmatically (see Dictation.swift) so
//  the SAME path serves the on-screen mic and the Action button. Tap the mic → system
//  dictation opens listening → speak → text appends to the draft.
//  (SFSpeechRecognizer doesn't work on watchOS, so an in-app always-on listener isn't
//  possible; this is the real, high-quality dictation.)
//
//  SEND is the hardware DOUBLE PINCH (`.handGestureShortcut(.primaryAction)`, Series 9 /
//  Ultra 2+). The Send button is ALWAYS visible and stays ENABLED whenever there's a draft
//  and the socket is alive (not permanently dead) — even mid-reconnect. A disabled button
//  can't anchor Double Tap (that's what produced the "no primary action" error) and also
//  swallows taps, so we keep it live; the store queues the prompt if the socket isn't ready.
//
//  Bottom bar = exactly 4 buttons: [mode] [dictate] [edit] [send]. Projects + the connection
//  dot moved UP to the top toolbar (RootView). Dictate is the prominent orange button.
//  Tapping the draft box (or the pencil) opens the crown-cursor editor (CaretEditorView).
//

import SwiftUI

struct ComposerView: View {
    @EnvironmentObject private var store: PinchStore
    @State private var showEditor = false
    @State private var showModes = false

    /// Send is live whenever there's something to send AND the socket isn't permanently dead.
    /// This keeps the double-pinch primary action anchored to a real, enabled target.
    private var canSend: Bool {
        store.connection.isAlive && !store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 4) {
            // Draft input box — a chat-style box holding the dictated/typed message. Scrolls
            // internally when the message runs long (capped at ~3-4 lines). Tap to edit.
            Button { showEditor = true } label: {
                ScrollView(.vertical) {
                    Text(store.draft.isEmpty ? "Tap mic to dictate…" : store.draft)
                        .font(.system(size: 14))
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(store.draft.isEmpty ? .secondary : .primary)
                }
                .frame(maxHeight: 76)            // ~3-4 lines, then it scrolls inside the box
                .scrollIndicators(.automatic)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.10)))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(store.draft.isEmpty ? Color.white.opacity(0.15) : Color.pinch.opacity(0.7), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 6)

            // Bottom bar: [mode] [dictate] [edit] [send]. Outer buttons (mode, send) get extra
            // bottom inset + a bigger outer corner radius so they curve away from the watch's
            // rounded screen corners; the middle two sit lowest.
            HStack(alignment: .bottom, spacing: 6) {
                // Mode (default / acceptEdits / plan / bypass). Red when bypass is armed. Outer-left.
                BarButton(systemName: store.mode.symbol,
                          tint: store.mode == .bypassPermissions ? .red : .primary,
                          label: "Mode",
                          prominent: false,
                          corner: .left) {
                    showModes = true
                }

                // Dictate — the prominent, orange-filled primary input. Left of middle.
                BarButton(systemName: "mic.fill",
                          tint: .pinch,
                          label: "Dictate",
                          prominent: true,
                          corner: .none) {
                    Dictation.present { store.appendDictated($0) }
                }

                // Edit — opens the crown-cursor editor directly (replaces the old "…" overflow).
                BarButton(systemName: "pencil",
                          tint: .primary,
                          label: "Edit message",
                          prominent: false,
                          corner: .none) {
                    showEditor = true
                }

                // Send — ALWAYS visible, enabled whenever canSend, carries the double-pinch
                // primary action. Outer-right.
                SendButton(enabled: canSend, corner: .right) { store.send(store.draft) }
            }
            .padding(.horizontal, 8)            // clear the rounded screen corners
        }
        .padding(.bottom, 2)
        .animation(.snappy, value: store.draft.isEmpty)
        .sheet(isPresented: $showEditor) {
            CaretEditorView(text: $store.draft, onSend: { store.send(store.draft) })
        }
        .sheet(isPresented: $showModes) { ModeMenuView() }
    }
}

// MARK: - Bottom-bar buttons

/// Which side of the row a button is on, so the outer ones can curve with the screen corner.
private enum BarCorner { case left, right, none }

/// Squat (≈20% shorter) bordered icon button. Outer buttons get a bigger outer-bottom corner
/// radius + extra bottom padding so they follow the Apple Watch Ultra's rounded screen corners.
private struct BarButton: View {
    let systemName: String
    let tint: Color
    let label: String
    let prominent: Bool
    let corner: BarCorner
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: prominent ? 19 : 16, weight: .semibold))
                .foregroundStyle(prominent ? .white : tint)
                .frame(maxWidth: .infinity, minHeight: 35)   // ~20% shorter than the old 44
                .background(background)
        }
        .buttonStyle(.plain)
        .padding(.bottom, corner == .none ? 0 : 4)           // edges ride a touch higher
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var background: some View {
        let shape = BarButtonShape(corner: corner)
        if prominent {
            shape.fill(tint)
        } else {
            shape.fill(Color.white.opacity(0.14))
        }
    }
}

/// Send button — its own type so the `.handGestureShortcut(.primaryAction)` stays anchored to
/// a single visible, enabled control.
private struct SendButton: View {
    let enabled: Bool
    let corner: BarCorner
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "paperplane.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 35)
                .background(BarButtonShape(corner: corner).fill(Color.pinch.opacity(enabled ? 1.0 : 0.4)))
        }
        .buttonStyle(.plain)
        .padding(.bottom, corner == .none ? 0 : 4)
        .disabled(!enabled)
        // Hardware double pinch → Send. The control stays enabled while the socket is alive so
        // this always has a live target; no-op on unsupported hardware (tap still works).
        .handGestureShortcut(.primaryAction)
        .accessibilityLabel("Send")
    }
}

/// Rounded-rect whose OUTER-bottom corner is rounded more than the inner ones, so the two edge
/// buttons approximate the watch's screen corner curve (middle of the row sits lowest).
private struct BarButtonShape: Shape {
    let corner: BarCorner
    private let inner: CGFloat = 9
    private let outer: CGFloat = 18

    func path(in rect: CGRect) -> Path {
        let topL = inner, topR = inner
        let botL = corner == .left ? outer : inner
        let botR = corner == .right ? outer : inner

        var p = Path()
        p.move(to: CGPoint(x: rect.minX + topL, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - topR, y: rect.minY))
        p.addArc(center: CGPoint(x: rect.maxX - topR, y: rect.minY + topR),
                 radius: topR, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - botR))
        p.addArc(center: CGPoint(x: rect.maxX - botR, y: rect.maxY - botR),
                 radius: botR, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX + botL, y: rect.maxY))
        p.addArc(center: CGPoint(x: rect.minX + botL, y: rect.maxY - botL),
                 radius: botL, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + topL))
        p.addArc(center: CGPoint(x: rect.minX + topL, y: rect.minY + topL),
                 radius: topL, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }
}
