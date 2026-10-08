import Foundation

struct RealtimeRetryPolicy: Sendable {
    private(set) var failures = 0
    private(set) var retryAt = Date.distantPast
    func permitsAttempt(at now: Date) -> Bool { now >= retryAt }
    mutating func failed(at now: Date, jitter: Double = Double.random(in: 0.8...1.2)) {
        failures = min(failures + 1, 7)
        let seconds = min(60, pow(2, Double(failures - 1)) * min(1.2, max(0.8, jitter)))
        retryAt = now.addingTimeInterval(seconds)
    }
    mutating func succeeded() { failures = 0; retryAt = .distantPast }
}

/// Realtime messages are wake-up hints. Call and ink state are always fetched by authenticated RPC.
public actor RealtimeHints {
    private var generation = UUID()
    private var retry = RealtimeRetryPolicy()
    private var connecting = false
    private var teamID: UUID?
    private var sessionID: UUID?
    public var connected: Bool { socket?.state == .running && !connecting }
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var pongTimeout: Task<Void, Never>?
    private var pendingPing: UUID?
    public init() {}
    public static func awsSocketURL(configuration: RemoteConfiguration, ticket: String) throws -> URL {
        guard configuration.provider == .aws, let endpoint = configuration.webSocketURL,
              !ticket.isEmpty, ticket.count <= 2048, ticket.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_".contains($0)) }),
              var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { throw RemoteError.configuration }
        components.queryItems = [URLQueryItem(name: "ticket", value: ticket)]
        guard let url = components.url else { throw RemoteError.configuration }; return url
    }
    public func connect(api: RemoteAPI, token: String, teamID: UUID, sessionID: UUID?,
                        changed: @escaping @Sendable () async -> Void) async throws {
        if self.teamID != teamID || self.sessionID != sessionID { disconnect(); self.teamID = teamID; self.sessionID = sessionID }
        if connecting || connected { return }
        guard retry.permitsAttempt(at: Date()) else { throw RemoteError.unavailable }
        stopSocket()
        let captured = generation
        connecting = true
        defer { if captured == generation { connecting = false } }
        do { try await openSocket(api: api, token: token, teamID: teamID, sessionID: sessionID, captured: captured, changed: changed) }
        catch { failed(captured); throw error }
    }
    private func openSocket(api: RemoteAPI, token: String, teamID: UUID, sessionID: UUID?, captured: UUID,
                            changed: @escaping @Sendable () async -> Void) async throws {
        let configuration = api.configuration
        if configuration.provider == .aws {
            var payload: [String: RemoteJSON] = ["team_id": .id(teamID)]
            if let sessionID { payload["session_id"] = .id(sessionID) }
            let receipt = try await api.json("functions/v1/realtime-ticket", token: token, body: .object(payload))
            guard captured == generation else { throw RemoteError.authentication }
            let url = try Self.awsSocketURL(configuration: configuration, ticket: receipt.requiredText("ticket"))
            let socket = URLSession.shared.webSocketTask(with: url); self.socket = socket; socket.resume()
            receiveTask = Task {
                while !Task.isCancelled {
                    do {
                        let message = try await socket.receive(), data: Data
                        guard captured == generation else { return }; retry.succeeded()
                        switch message { case .data(let v): data = v; case .string(let v): data = Data(v.utf8); @unknown default: continue }
                        guard data.count <= 64 * 1024, let value = try? JSONDecoder().decode(RemoteJSON.self, from: data),
                              value["type"].text == "changed", value["team_id"].uuid == teamID else { continue }
                        await changed()
                    } catch { failed(captured); return }
                }
            }
            heartbeatTask = Task {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(60)); ping(socket, captured: captured); try await socket.send(.string("{\"action\":\"heartbeat\"}")) }
                    catch { failed(captured); return }
                }
            }
            await changed()
            return
        }
        guard let sessionID else { return }
        var url = URLComponents(url: configuration.url, resolvingAgainstBaseURL: false)!
        url.scheme = configuration.url.scheme == "https" ? "wss" : "ws"
        url.path = "/realtime/v1/websocket"
        url.queryItems = [URLQueryItem(name: "apikey", value: configuration.publishableKey), URLQueryItem(name: "vsn", value: "2.0.0")]
        let socket = URLSession.shared.webSocketTask(with: url.url!); self.socket = socket; socket.resume()
        let topic = "realtime:worshipcue:\(sessionID.uuidString.lowercased())"
        let join = RemoteJSON.array([.string("1"), .string("1"), .string(topic), .string("phx_join"), .object([
            "access_token": .string(token), "config": .object(["postgres_changes": .array([
                .object(["event": .string("*"), "schema": .string("public"), "table": .string("live_sessions"), "filter": .string("id=eq.\(sessionID.uuidString.lowercased())")]),
                .object(["event": .string("*"), "schema": .string("public"), "table": .string("annotation_heads")])])])])])
        try await socket.send(.data(JSONEncoder().encode(join)))
        receiveTask = Task {
            while !Task.isCancelled {
                do {
                    let message = try await socket.receive()
                    guard captured == generation else { return }; retry.succeeded()
                    let data: Data
                    switch message { case .data(let v): data = v; case .string(let v): data = Data(v.utf8); @unknown default: continue }
                    guard data.count <= 1024 * 1024, let value = try? JSONDecoder().decode(RemoteJSON.self, from: data), value.list.count == 5 else { continue }
                    let values = value.list
                    guard values[2].text == topic else { continue }
                    if values[3].text == "postgres_changes" || (values[3].text == "phx_reply" && values[4]["status"].text == "ok") { await changed() }
                } catch { failed(captured); return }
            }
        }
        heartbeatTask = Task {
            var sequence = 2
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(25))
                    let heartbeat = RemoteJSON.array([.null, .string(String(sequence)), .string("phoenix"), .string("heartbeat"), .object([:])])
                    try await socket.send(.data(JSONEncoder().encode(heartbeat))); sequence += 1
                } catch { failed(captured); return }
            }
        }
    }
    private func ping(_ socket: URLSessionWebSocketTask, captured: UUID) {
        let probe = UUID(); pendingPing = probe; pongTimeout?.cancel()
        pongTimeout = Task {
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            guard captured == generation, pendingPing == probe else { return }
            failed(captured)
        }
        socket.sendPing { [weak self] error in
            let failed = error != nil
            Task { await self?.receivedPong(probe, captured: captured, failed: failed) }
        }
    }
    private func receivedPong(_ probe: UUID, captured: UUID, failed: Bool) {
        guard captured == generation, pendingPing == probe else { return }
        if failed { self.failed(captured) }
        else { pongTimeout?.cancel(); pongTimeout = nil; pendingPing = nil; retry.succeeded() }
    }
    private func failed(_ captured: UUID) {
        guard captured == generation else { return }
        retry.failed(at: Date()); stopSocket()
    }
    private func stopSocket() {
        generation = UUID(); connecting = false
        receiveTask?.cancel(); heartbeatTask?.cancel(); pongTimeout?.cancel(); pongTimeout = nil; pendingPing = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        receiveTask = nil; heartbeatTask = nil; socket = nil
    }
    public func disconnect() { stopSocket(); retry.succeeded(); teamID = nil; sessionID = nil }
}
