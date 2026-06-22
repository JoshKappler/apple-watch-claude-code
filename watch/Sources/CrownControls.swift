//
//  CrownControls.swift
//  The crown IS the select button. watchOS gives apps no Digital Crown *press* event
//  (the press is hard-reserved by the system for Home/Siri/Apple Pay — confirmed against
//  Apple's HIG), so every "confirm/select" here is driven by crown ROTATION instead, and
//  the app never has to leave the screen.
//
//  Two reusable patterns, both built on the plain `.digitalCrownRotation` binding overload
//  (the most broadly available one) + `.onChange` + a small idle/dwell timer, so there's no
//  dependency on the newer detent/onIdle closure overloads:
//
//    • CrownConfirm — binary yes/no. Rotate clockwise past a threshold to approve, counter-
//      clockwise past it to deny; if you stop short it springs back to center. Used for the
//      permission gate. Screen taps remain as an explicit shortcut.
//
//    • CrownPicker  — pick one of N. Rotation snaps a highlight through the rows (a haptic
//      tick per row); stop on one and a ring fills over ~0.65s to commit (dwell-to-commit).
//      Tapping a row commits immediately. Used for the mode and project menus.
//
//  A crown-driven view must be `.focusable()` and hold focus to receive rotation, so each
//  grabs focus on appear (only one crown-focused view per screen).
//

import SwiftUI
import WatchKit

// MARK: - Binary confirm (spring-loaded threshold)

struct CrownConfirm: View {
    var approveTitle: String = "Approve"
    var denyTitle: String = "Deny"
    /// How far the crown must travel (0...1) toward a side before it commits.
    var threshold: Double = 0.8
    let onApprove: () -> Void
    let onDeny: () -> Void

    @State private var value = 0.0          // -1 (deny) ... +1 (approve), rests at 0
    @State private var committed = false
    @State private var springTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            // Directional fill matches the up/down hint: GREEN grows from the top as you turn the
            // crown UP toward approve, RED grows from the bottom as you turn DOWN toward deny.
            VStack(spacing: 0) {
                Rectangle().fill(Color.green.opacity(value > 0 ? min(value, 1) * 0.5 : 0))
                Rectangle().fill(Color.red.opacity(value < 0 ? min(-value, 1) * 0.5 : 0))
            }
            .allowsHitTesting(false)

            // Crown UP = approve, crown DOWN = deny — shown with literal up/down arrows so the
            // direction you turn maps to the direction of the label (the crown scrolls vertically).
            VStack(spacing: 2) {
                Label(approveTitle, systemImage: "arrow.up")
                    .font(.system(size: 12, weight: value > 0.05 ? .semibold : .regular))
                    .foregroundStyle(value > 0.05 ? .green : .secondary)
                Image(systemName: glyph)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(value > 0.05 ? .green : value < -0.05 ? .red : .secondary)
                Label(denyTitle, systemImage: "arrow.down")
                    .font(.system(size: 12, weight: value < -0.05 ? .semibold : .regular))
                    .foregroundStyle(value < -0.05 ? .red : .secondary)
            }
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 8)
        }
        .frame(maxWidth: .infinity, minHeight: 70)
        .focusable(true)
        .focused($focused)
        .digitalCrownRotation(
            $value, from: -1.0, through: 1.0, by: nil,
            sensitivity: .medium, isContinuous: false, isHapticFeedbackEnabled: false
        )
        .onChange(of: value) { _, v in
            guard !committed else { return }
            if v >= threshold {
                commit(approve: true)
            } else if v <= -threshold {
                commit(approve: false)
            } else {
                scheduleSpringBack()
            }
        }
        .onAppear { focused = true }
        .accessibilityElement()
        .accessibilityLabel("Turn crown up to \(approveTitle), down to \(denyTitle)")
    }

    private var glyph: String {
        if value > 0.05 { return "checkmark.circle.fill" }
        if value < -0.05 { return "xmark.circle.fill" }
        return "dial.medium.fill"
    }

    private func commit(approve: Bool) {
        committed = true
        springTask?.cancel()
        WKInterfaceDevice.current().play(approve ? .success : .failure)
        if approve { onApprove() } else { onDeny() }
    }

    /// If the crown stops short of the threshold, ease the value back to center.
    private func scheduleSpringBack() {
        springTask?.cancel()
        springTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, !committed else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { value = 0 }
        }
    }
}

// MARK: - List picker (detent highlight + dwell-to-commit)

struct CrownPicker<Item: Identifiable>: View {
    let items: [Item]
    let title: (Item) -> String
    var subtitle: ((Item) -> String?)? = nil
    /// Index pre-selected when the picker appears (e.g. the current project).
    var initialIndex: Int = 0
    /// Verb shown on the confirm bar before the highlighted item's name (e.g. "Open").
    var confirmVerb: String = "Select"
    let onCommit: (Item) -> Void

    @State private var value = 0.0
    @State private var index = 0
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 4) {
            // The crown HIGHLIGHTS rows and SCROLLS the highlight into view (same model as the
            // edit-mode caret) — so the selection is always visible even when the list overflows.
            // It no longer auto-commits; you confirm explicitly below.
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(spacing: 6) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                            row(item, selected: i == index)
                                .id(i)
                                .contentShape(Rectangle())
                                .onTapGesture { select(i) }   // tap a row to highlight it
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: .infinity)   // take the space above the confirm bar
                .focusable(true)
                .focused($focused)
                .digitalCrownRotation(
                    $value, from: 0, through: Double(max(items.count - 1, 0)), by: nil,
                    sensitivity: .low, isContinuous: false, isHapticFeedbackEnabled: false
                )
                .onChange(of: value) { _, v in
                    let clamped = min(max(Int(v.rounded()), 0), max(items.count - 1, 0))
                    if clamped != index {
                        index = clamped
                        WKInterfaceDevice.current().play(.click)   // per-row tick
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(index, anchor: .center) }
                    }
                }
                .onChange(of: index) { _, i in
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(i, anchor: .center) }
                }
                .onAppear {
                    index = min(max(initialIndex, 0), max(items.count - 1, 0))
                    value = Double(index)
                    focused = true
                    proxy.scrollTo(index, anchor: .center)
                }
            }

            // CONFIRM the highlighted row. Lives OUTSIDE the ScrollView on purpose: a
            // .handGestureShortcut(.primaryAction) inside a ScrollView/List doesn't receive the
            // hardware double-pinch, so this fixed bar carries it. Tap it OR double-pinch to open.
            if items.indices.contains(index) {
                Button { commit(at: index) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                        Text("\(confirmVerb) \(title(items[index]))")
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                }
                .buttonStyle(.borderedProminent)
                .tint(.pinch)
                .handGestureShortcut(.primaryAction)
                .padding(.horizontal, 6)
                .padding(.bottom, 2)
                .accessibilityLabel("\(confirmVerb) \(title(items[index]))")
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func row(_ item: Item, selected: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 12))
                .foregroundStyle(selected ? Color.pinch : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title(item))
                    .font(.system(size: 14, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
                if let sub = subtitle?(item), !sub.isEmpty {
                    Text(sub).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(selected ? Color.pinch.opacity(0.16) : Color.clear, in: .rect(cornerRadius: 8))
    }

    /// Highlight a row (tap or crown). Keeps the crown value in sync so a following turn continues
    /// from here rather than snapping back.
    private func select(_ i: Int) {
        guard items.indices.contains(i) else { return }
        index = i
        value = Double(i)
        WKInterfaceDevice.current().play(.click)
    }

    private func commit(at i: Int) {
        guard items.indices.contains(i) else { return }
        WKInterfaceDevice.current().play(.success)
        onCommit(items[i])
    }
}
