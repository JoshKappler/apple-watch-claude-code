//
//  WSClient.swift
//  URLSessionWebSocketTask client for the Pinch wire protocol.
//
//  Responsibilities:
//   • Connect to <serverURL>/ws with `Authorization: Bearer <token>` header
//     (defense-in-depth; the watch CAN set WS headers, unlike browsers).
//   • Send the first-frame `auth` immediately on open, then drive a receive loop.
//   • Heartbeat: app-level `ping` every ~25s (Cloudflare drops idle WS at 100s).
//   • Reconnect with exponential backoff + jitter; resume the agent session via
//     resumeSessionId captured from the last `ready`.
//   • Re-arm `receive` after every message; surface decoded ServerMsg via a callback.
//
//  Foreground-only by design: watchOS reclaims the socket on suspend. The Store
//  connects on scenePhase .active and disconnects on background.
//

import Foundation

/// High-level connection state for the UI badge.
enum ConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected          // socket open, auth sent, awaiting `ready`
    case ready              // `ready` received — fully usable
    case reconnecting(attempt: Int)
    case failed(String)     // fatal (bad token / version) — needs user action
}

/// Owns the socket lifecycle. Not @MainActor: it runs its own async loops and
/// hops to the main actor only via the two callbacks below.
final class WSClient: NSObject, @unchecked Sendable {

    // Configuration, set before connect().
    private var serverURL: URL
    private var token: String
    private let deviceId: String

    // Callbacks — invoked on the main actor by the Store.
    var onState: (@MainActor (ConnectionState) -> Void)?
    var onMessage: (@MainActor (ServerMsg) -> Void)?

    private var session: URLSession!
    private var task: URLSessionWebSocketTask?

    private var resumeSessionId: String?
    private var heartbeatTask: Task<Void, Never>?
    private var receiveLoopActive = false

    // Reconnect bookkeeping.
    private var reconnectAttempt = 0
    private var shouldStayConnected = false
    private var reconnectTask: Task<Void, Never>?

    init(serverURL: URL, token: String, deviceId: String) {
        self.serverURL = serverURL
        self.token = token
        self.deviceId = deviceId
        super.init()
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 30
        // delegate gives us didOpen / didClose for clean state transitions.
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    /// Update credentials/URL (from Settings). Caller should reconnect() after.
    func configure(serverURL: URL, token: String) {
        self.serverURL = serverURL
        self.token = token
    }

    // MARK: - Lifecycle

    func connect() {
        shouldStayConnected = true
        reconnectTask?.cancel()
        openSocket()
    }

    func disconnect() {
        shouldStayConnected = false
        reconnectTask?.cancel()
        reconnectTask = nil
        teardownSocket(notify: true)
    }

    /// Force a fresh attempt now (e.g. user tapped "reconnect" or settings changed).
    func reconnectNow() {
        teardownSocket(notify: false)
        reconnectAttempt = 0
        if shouldStayConnected { openSocket() }
    }

    private func openSocket() {
        teardownSocket(notify: false)
        emit(.connecting)

        guard let wsURL = makeWebSocketURL() else {
            emit(.failed("Bad server URL"))
            return
        }

        var request = URLRequest(url: wsURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let t = session.webSocketTask(with: request)
        self.task = t
        self.receiveLoopActive = true
        t.resume()
        // didOpen (delegate) fires → we send `auth` and start the receive loop there.
    }

    private func teardownSocket(notify: Bool) {
        heartbeatTask?.cancel(); heartbeatTask = nil
        receiveLoopActive = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        if notify { emit(.disconnected) }
    }

    /// Build the `/ws` URL from the user's base URL. Accepts http(s)/ws(s); upgrades to wss.
    private func makeWebSocketURL() -> URL? {
        guard var comps = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else { return nil }
        switch comps.scheme?.lowercased() {
        case "ws", "wss": break
        case "http": comps.scheme = "ws"
        default: comps.scheme = "wss"        // https or anything else → wss
        }
        // Ensure path ends in /ws exactly once.
        var path = comps.path
        if path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix("/ws") { path += "/ws" }
        comps.path = path
        return comps.url
    }

    // MARK: - Auth + receive

    private func sendAuth() {
        let msg = ClientMsg.auth(token: token, deviceId: deviceId, resumeSessionId: resumeSessionId)
        send(msg)
        emit(.connected)
    }

    private func receiveLoop() {
        guard let task, receiveLoopActive else { return }
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(message):
                self.handle(message)
                self.receiveLoop()      // re-arm for the next frame
            case let .failure(error):
                // Socket died — schedule a reconnect (unless we're tearing down on purpose).
                if self.receiveLoopActive {
                    self.handleSocketDrop(error)
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data?
        switch message {
        case let .string(s): data = s.data(using: .utf8)
        case let .data(d): data = d
        @unknown default: data = nil
        }
        guard let data else { return }

        guard let decoded = try? JSONDecoder().decode(ServerMsg.self, from: data) else {
            // Malformed frame — ignore (don't kill the loop).
            return
        }

        // Capture sessionId for resume; flip to .ready; clear backoff on success.
        if case let .ready(ready) = decoded {
            resumeSessionId = ready.sessionId
            reconnectAttempt = 0
            startHeartbeat()
            emit(.ready)
        }

        Task { @MainActor [weak self] in self?.onMessage?(decoded) }
    }

    // MARK: - Sending

    func send(_ msg: ClientMsg) {
        guard let task else { return }
        guard let json = try? msg.jsonString() else { return }
        task.send(.string(json)) { _ in /* best-effort; drops surface via receive failure */ }
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 25_000_000_000) // ~25s
                guard let self, !Task.isCancelled else { return }
                self.send(.ping(t: Date().timeIntervalSince1970))
            }
        }
    }

    // MARK: - Reconnect (exponential backoff + jitter)

    private func handleSocketDrop(_ error: Error) {
        teardownSocket(notify: false)
        guard shouldStayConnected else { emit(.disconnected); return }
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        reconnectAttempt += 1
        let attempt = reconnectAttempt
        emit(.reconnecting(attempt: attempt))

        // base 0.8s, doubling, capped at 30s, plus up to ±30% jitter.
        let capped = min(pow(2.0, Double(attempt - 1)) * 0.8, 30.0)
        let jitter = Double.random(in: 0.7...1.3)
        let delay = capped * jitter

        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, self.shouldStayConnected else { return }
            self.openSocket()
        }
    }

    private func emit(_ state: ConnectionState) {
        Task { @MainActor [weak self] in self?.onState?(state) }
    }
}

// MARK: - URLSessionWebSocketDelegate

extension WSClient: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        // Socket is open — send the mandatory first `auth` frame, then start receiving.
        sendAuth()
        receiveLoop()
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        // Fatal close codes from the server should NOT auto-retry forever.
        let raw = closeCode.rawValue
        if raw == Pinch.CloseCode.authFailed {
            shouldStayConnected = false
            emit(.failed("Auth failed — check your token."))
            return
        }
        if raw == Pinch.CloseCode.protocolMismatch {
            shouldStayConnected = false
            emit(.failed("Protocol version mismatch — update the app."))
            return
        }
        // Any other close: treat as a transient drop and reconnect (if we still want to be up).
        if receiveLoopActive {
            handleSocketDrop(URLError(.networkConnectionLost))
        }
    }
}
