//
//  DemoSeed.swift
//  PORTFOLIO / SCREENSHOT scaffolding — NOT shipped behavior. Everything here is gated behind the
//  `PINCH_DEMO` launch environment variable, so a normal install (which never sets it) is completely
//  unaffected: no demo data, no connection suppression. It exists only so the simulator can render
//  realistic, populated screens (a live conversation, a permission card with a diff, the multi-agent
//  switcher) for portfolio screenshots without a running backend to talk to.
//
//  Drive it with:  xcrun simctl launch <udid> <bundleid> --env PINCH_DEMO=conversation
//

import Foundation

/// The demo screen to stage, read once from the launch environment.
enum Demo {
    /// nil for a normal launch. Otherwise the requested screen ("conversation", "permission",
    /// "thinking", "agents", "settings", "mode", "project"). "1"/"true" alias to "conversation".
    static var screen: String? {
        guard let raw = ProcessInfo.processInfo.environment["PINCH_DEMO"]?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else { return nil }
        return (raw == "1" || raw == "true") ? "conversation" : raw
    }

    static var isActive: Bool { screen != nil }
}

@MainActor
extension PinchStore {
    /// Populate the store with believable, hand-written demo state so the UI renders a real-looking
    /// session offline. Idempotent — the non-empty transcript guards against a re-seed on every
    /// scenePhase activation.
    func applyDemoSeed() {
        guard Demo.isActive, transcript.isEmpty else { return }

        // A connected, named session with a partially-full context window (so the gear ring shows).
        connection = .ready
        sessionId = "demo-session"
        contextUsed = 84_000
        contextWindow = 200_000
        selectedModel = "claude-opus-4-8"
        thinkingLevel = .high

        // The multi-agent switcher: two projects, three running agents, "Rate limiting" focused.
        agents = [
            AgentSlot(id: "default", label: "pinch-backend",
                      projectName: "pinch-backend", projectPath: "/Users/josh/pinch-backend",
                      title: "Rate limiting"),
            AgentSlot(id: "a2", label: "jobhunt",
                      projectName: "jobhunt", projectPath: "/Users/josh/jobhunt",
                      title: "Fix apply button"),
            AgentSlot(id: "a3", label: "jobhunt",
                      projectName: "jobhunt", projectPath: "/Users/josh/jobhunt",
                      title: "Resume parser"),
        ]
        focusedAgentId = "default"
        currentProject = ProjectRef(id: "pinch-backend", name: "pinch-backend",
                                    path: "/Users/josh/pinch-backend", branch: "main", dirty: true)

        // A short, realistic conversation: ask → tools → answer.
        transcript = [
            .user(text: "Add rate limiting to the login route"),
            .assistant(text: "On it — adding a per-IP token-bucket limiter to the auth middleware and wiring it into the login handler."),
            .tool(.init(id: "t1", name: "Read", title: "Read auth.ts", subtitle: "src/middleware"), ok: true),
            .tool(.init(id: "t2", name: "Edit", title: "Edit rateLimit.ts", subtitle: "+12 −1"), ok: true),
            .assistant(text: "Done. 5 requests/min per IP on /login, returning 429 + Retry-After. Want me to add a test?"),
        ]

        switch Demo.screen {
        case "permission":
            agentState = .waiting_permission
            pendingPermission = ServerMsg.PermissionRequest(
                requestId: "req-1",
                tool: "Edit",
                title: "Edit rateLimit.ts",
                detail: nil,
                risk: .medium,
                kind: .edit,
                diff: """
                @@ login handler @@
                -app.post('/login', loginHandler)
                +app.post('/login',
                +  rateLimit({ max: 5, window: '1m' }),
                +  loginHandler)
                """,
                command: nil
            )

        case "thinking":
            agentState = .thinking
            thinkingActive = true
            turnStartedAt = Date().addingTimeInterval(-23)   // shows a live ~23s elapsed timer
            transcript.append(.user(text: "Now add a test for the 429 path"))

        default:
            agentState = .idle
        }
    }
}
