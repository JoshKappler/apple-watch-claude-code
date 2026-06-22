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
//  Threading: all internal state is touched only on `queue` (a private serial queue).
//  The URLSession delegate callbacks and the receive completion handlers are funneled
//  onto it, and public entry points hop onto it too. The two callbacks fire on the
//  main actor for the SwiftUI Store. This keeps the class data-race-free.
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

/// Owns the socket lifecycle. State is confined to `queue`; callbacks hop to main.
final class WSClient: NSObject, @unchecked Sendable {

    // Configuration (only mutated on `queue`).
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
    /// True once we've received `ready` at least once on the current credentials.
    /// If we never reach ready after several tries, it's almost certainly a bad token /
    /// version mismatch (watchOS can't read the 4401/4426 numeric close code from the
    /// CloseCode enum), so we stop hammering and surface a .failed state.
    private var everReachedReady = false
    private let maxColdAttempts = 4

    /// Serial queue that confines all internal state mutation.
    private let queue = DispatchQueue(label: "com.josh.pinch.ws")

    init(serverURL: URL, token: String, deviceId: String) {
        self.serverURL = serverURL
        self.token = token
        self.deviceId = deviceId
        super.init()
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 30
        // Run delegate callbacks on our serial queue so they're serialized with everything else.
        let opQueue = OperationQueue()
        opQueue.underlyingQueue = queue
        opQueue.maxConcurrentOperationCount = 1
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: opQueue)
    }

    /// Update credentials/URL (from Settings). Caller should reconnect() after.
    func configure(serverURL: URL, token: String) {
        queue.async {
            // New credentials → give them a fresh shot at reaching ready.
            if self.serverURL != serverURL || self.token != token {
                self.everReachedReady = false
            }
            self.serverURL = serverURL
            self.token = token
        }
    }

    // MARK: - Lifecycle

    func connect() {
        queue.async {
            self.shouldStayConnected = true
            self.reconnectTask?.cancel()
            self.openSocket()
        }
    }

    func disconnect() {
        queue.async {
            self.shouldStayConnected = false
            self.reconnectTask?.cancel()
            self.reconnectTask = nil
            self.teardownSocket(notify: true)
        }
    }

    /// Force a fresh attempt now (e.g. user tapped "reconnect" or settings changed).
    func reconnectNow() {
        queue.async {
            self.shouldStayConnected = true
            self.everReachedReady = false   // user asked to retry — clear the cold-attempt latch.
            self.teardownSocket(notify: false)
            self.reconnectAttempt = 0
            self.openSocket()
        }
    }

    // All `private` methods below assume they run on `queue`.

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
        sendRaw(msg)
        emit(.connected)
    }

    private func receiveLoop() {
        guard let task, receiveLoopActive else { return }
        task.receive { [weak self] result in
            // Completion runs on `queue` (the session's delegate/underlying queue).
            guard let self else { return }
            switch result {
            case let .success(message):
                self.handle(message)
                self.receiveLoop()      // re-arm for the next frame
            case let .failure(error):
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
            return  // malformed frame — ignore (don't kill the loop).
        }

        // Capture sessionId for resume; flip to .ready; clear backoff on success.
        if case let .ready(ready) = decoded {
            resumeSessionId = ready.sessionId
            reconnectAttempt = 0
            everReachedReady = true
            startHeartbeat()
            emit(.ready)
        }

        Task { @MainActor [weak self] in self?.onMessage?(decoded) }
    }

    // MARK: - Sending

    /// Public send — marshals onto `queue` so it's serialized with the socket lifecycle.
    func send(_ msg: ClientMsg) {
        queue.async { self.sendRaw(msg) }
    }

    private func sendRaw(_ msg: ClientMsg) {
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

        // If we keep dropping before ever reaching `ready`, it's almost certainly auth /
        // version (we can't read the 4401/4426 numeric close code on watchOS). Stop retrying
        // and tell the user to check their token, rather than hammering forever.
        if !everReachedReady && attempt > maxColdAttempts {
            shouldStayConnected = false
            emit(.failed("Can't authenticate — check the server URL and token."))
            return
        }

        emit(.reconnecting(attempt: attempt))

        // base 0.8s, doubling, capped at 30s, plus up to ±30% jitter.
        let capped = min(pow(2.0, Double(attempt - 1)) * 0.8, 30.0)
        let jitter = Double.random(in: 0.7...1.3)
        let delay = capped * jitter

        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.queue.async {
                guard self.shouldStayConnected else { return }
                self.openSocket()
            }
        }
    }

    private func emit(_ state: ConnectionState) {
        Task { @MainActor [weak self] in self?.onState?(state) }
    }
}

// MARK: - URLSessionWebSocketDelegate

extension WSClient: URLSessionWebSocketDelegate {
    // These fire on `queue` (the session's underlying queue), so they're already serialized.
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
