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
            // Directional fill: red grows left as you turn toward deny, green right toward approve.
            HStack(spacing: 0) {
                Rectangle().fill(Color.red.opacity(value < 0 ? min(-value, 1) * 0.5 : 0))
                Rectangle().fill(Color.green.opacity(value > 0 ? min(value, 1) * 0.5 : 0))
            }
            .allowsHitTesting(false)

            VStack(spacing: 3) {
                Image(systemName: glyph)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(value > 0.05 ? .green : value < -0.05 ? .red : .secondary)
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
        }
        .frame(maxWidth: .infinity, minHeight: 56)
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
        .accessibilityLabel("Turn crown right to \(approveTitle), left to \(denyTitle)")
    }

    private var glyph: String {
        if value > 0.05 { return "checkmark.circle.fill" }
        if value < -0.05 { return "xmark.circle.fill" }
        return "dial.medium.fill"
    }

    private var label: String {
        if value > 0.05 { return "\(approveTitle) →" }
        if value < -0.05 { return "← \(denyTitle)" }
        return "turn → \(approveTitle) · ← \(denyTitle)"
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
    /// Index pre-selected when the picker appears (e.g. the current mode).
    var initialIndex: Int = 0
    /// Seconds the highlight must dwell on a row before it auto-commits.
    var dwell: Double = 0.65
    let onCommit: (Item) -> Void

    @State private var value = 0.0
    @State private var index = 0
    @State private var progress = 0.0       // 0...1 dwell ring fill
    @State private var hasMoved = false     // don't auto-commit before any interaction
    @State private var dwellTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                row(item, selected: i == index)
                    .contentShape(Rectangle())
                    .onTapGesture { commit(at: i) }   // tap = instant commit shortcut
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 6)
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
                hasMoved = true
                WKInterfaceDevice.current().play(.click)   // per-row tick
            }
            scheduleDwell()
        }
        .onAppear {
            index = min(max(initialIndex, 0), max(items.count - 1, 0))
            value = Double(index)
            focused = true
        }
    }

    @ViewBuilder
    private func row(_ item: Item, selected: Bool) -> some View {
        HStack(spacing: 6) {
            ZStack {
                if selected {
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(Color.green, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 16, height: 16)
                }
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(selected ? .green : .secondary)
            }
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
        .background(selected ? Color.white.opacity(0.10) : Color.clear, in: .rect(cornerRadius: 8))
    }

    private func scheduleDwell() {
        dwellTask?.cancel()
        progress = 0
        guard hasMoved else { return }      // require interaction before auto-committing
        dwellTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))   // ignore quick fly-overs
            guard !Task.isCancelled else { return }
            withAnimation(.linear(duration: dwell)) { progress = 1 }
            try? await Task.sleep(for: .seconds(dwell))
            guard !Task.isCancelled else { return }
            commit(at: index)
        }
    }

    private func commit(at i: Int) {
        dwellTask?.cancel()
        guard items.indices.contains(i) else { return }
        WKInterfaceDevice.current().play(.success)
        onCommit(items[i])
    }
}
