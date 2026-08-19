import Foundation

/// Talks to the Microsoft Teams local third-party app API on 127.0.0.1:8124.
///
/// Verified against Teams 26198.202.4929.7171: the socket accepts a plain WebSocket
/// upgrade, the first command raises a pairing prompt in Teams, approval returns a
/// `tokenRefresh` UUID, and reconnecting with that token in the query string succeeds
/// silently. Teams then pushes `meetingUpdate` on every state change, which is what
/// keeps the menu bar icon correct even when the user clicks mute inside Teams.
///
/// Everything here is best effort. Muting is already guaranteed by `AudioController`
/// before this class is ever asked to do anything, so a missing, disabled or
/// policy-blocked API costs nothing but the Teams-side indicator.
final class TeamsAPI {

    struct State: Equatable {
        var isInMeeting = false
        var isMuted = false
        var canToggleMute = false
    }

    private(set) var state = State()
    private(set) var isConnected = false

    var onChange: (() -> Void)?

    private static let tokenKey = "teamsApiToken"
    private static let port = 8124

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var requestID = 0
    private var reconnectDelay: TimeInterval = 1
    private var stopped = true

    /// Teams answers a command that arrives while pairing is unapproved with
    /// "Pairing request already pending" and drops it. Sending more only queues more
    /// rejections, so hold off until pairing resolves.
    private var pairingPending = false

    /// `toggle-mute` flips whatever Teams currently has. Firing a second one before
    /// the first is reflected in `meetingUpdate` would flip straight back.
    private var toggleInFlight = false

    // MARK: - Lifecycle

    func start() {
        guard stopped else { return }
        stopped = false
        connect()
    }

    func stop() {
        stopped = true
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        isConnected = false
    }

    private func connect() {
        guard !stopped else { return }

        var components = URLComponents()
        components.scheme = "ws"
        components.host = "127.0.0.1"
        components.port = Self.port
        components.path = "/"
        var items = [
            URLQueryItem(name: "protocol-version", value: "2.0.0"),
            URLQueryItem(name: "manufacturer", value: "MacMute"),
            URLQueryItem(name: "device", value: "MacMute"),
            URLQueryItem(name: "app", value: "MacMute"),
            URLQueryItem(name: "app-version", value: "1.0.0"),
        ]
        if let token = UserDefaults.standard.string(forKey: Self.tokenKey) {
            items.append(URLQueryItem(name: "token", value: token))
        }
        components.queryItems = items
        guard let url = components.url else { return }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: configuration)
        self.session = session

        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        receive()
    }

    private func scheduleReconnect() {
        guard !stopped else { return }
        isConnected = false
        state = State()
        pairingPending = false
        toggleInFlight = false
        DispatchQueue.main.async { self.onChange?() }

        let delay = reconnectDelay
        reconnectDelay = min(delay * 2, 30)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.connect()
        }
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                // Teams closed the socket, is not running, or the API is disabled.
                DispatchQueue.main.async { self.scheduleReconnect() }
            case .success(let message):
                if case .string(let text) = message {
                    DispatchQueue.main.async { self.handle(text) }
                }
                self.receive()
            }
        }
    }

    // MARK: - Incoming

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        if !isConnected {
            isConnected = true
            reconnectDelay = 1
        }

        if let token = json["tokenRefresh"] as? String {
            UserDefaults.standard.set(token, forKey: Self.tokenKey)
            pairingPending = false
        }

        if let response = json["response"] as? String {
            if response.localizedCaseInsensitiveContains("pairing") {
                pairingPending = true
            } else if response == "Success" {
                pairingPending = false
            }
        }

        if let update = json["meetingUpdate"] as? [String: Any] {
            var next = state
            if let permissions = update["meetingPermissions"] as? [String: Any],
               let canToggle = permissions["canToggleMute"] as? Bool {
                next.canToggleMute = canToggle
            }
            if let meeting = update["meetingState"] as? [String: Any] {
                if let inMeeting = meeting["isInMeeting"] as? Bool { next.isInMeeting = inMeeting }
                if let muted = meeting["isMuted"] as? Bool { next.isMuted = muted }
                // Teams has told us where it really is, so any toggle we sent has landed.
                toggleInFlight = false
            }
            if next != state {
                state = next
                onChange?()
                return
            }
        }
        onChange?()
    }

    // MARK: - Outgoing

    /// Brings Teams to `muted` if it is not already there. Never blocks, never reports
    /// failure upward — the caller has already guaranteed silence through the HAL.
    func setMuted(_ muted: Bool) {
        guard isConnected, state.canToggleMute, !pairingPending, !toggleInFlight else { return }
        guard state.isMuted != muted else { return }

        requestID += 1
        let command: [String: Any] = [
            "apiVersion": "2.0.0",
            "service": "toggle-mute",
            "action": "toggle-mute",
            "requestId": requestID,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: command),
              let text = String(data: data, encoding: .utf8) else { return }

        toggleInFlight = true
        task?.send(.string(text)) { [weak self] error in
            guard error != nil else { return }
            DispatchQueue.main.async { self?.toggleInFlight = false }
        }

        // Teams normally answers in milliseconds; if it does not, unblock so the next
        // keypress is not swallowed by a toggle that never completed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.toggleInFlight = false
        }
    }
}
