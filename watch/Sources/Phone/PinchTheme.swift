//
//  PinchTheme.swift
//  Shared visual language for the iPhone app — colors, status mapping.
//  Mirrors the watch's coral identity but tuned for a larger screen.
//

import SwiftUI

enum PinchTheme {
    /// Brand coral — matches the watch's user-bubble / accent color and the iOS AccentColor asset.
    static let accent = Color(red: 1.0, green: 0.42, blue: 0.357)

    /// Assistant bubble background.
    static let assistantBubble = Color(uiColor: .secondarySystemBackground)
    /// User bubble background.
    static let userBubble = accent
    static let userBubbleText = Color.white

    /// Monospace surface (code blocks, diffs, command previews).
    static let codeBackground = Color(uiColor: .tertiarySystemBackground)

    // MARK: - Status colors (fleet badges, connection dots)

    /// Color for a session's live agent state.
    static func color(for state: AgentState) -> Color {
        switch state {
        case .idle:               return .secondary
        case .thinking:           return .blue
        case .running_tool:       return .green
        case .waiting_permission: return .orange
        case .error:              return .red
        }
    }

    /// Short human label for an agent state (fleet rows).
    static func label(for state: AgentState) -> String {
        switch state {
        case .idle:               return "Idle"
        case .thinking:           return "Thinking"
        case .running_tool:       return "Running"
        case .waiting_permission: return "Needs you"
        case .error:              return "Error"
        }
    }

    /// Color for the transport connection state.
    static func color(for connection: ConnectionState) -> Color {
        switch connection {
        case .connected, .ready:        return .green
        case .connecting, .reconnecting: return .yellow
        case .disconnected:             return .secondary
        case .failed:                   return .red
        }
    }
}
