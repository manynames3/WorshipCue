import Foundation

/// Supabase/Phoenix messages are wake-up hints. Call and ink state are always fetched by authenticated RPC.
public actor RealtimeHints {
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    public init() {}
    public func connect(configuration: RemoteConfiguration, token: String, sessionID: UUID,
                        changed: @escaping @Sendable () async -> Void) async throws {
        disconnect()
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
                    let data: Data
                    switch message { case .data(let v): data = v; case .string(let v): data = Data(v.utf8); @unknown default: continue }
                    guard data.count <= 1024 * 1024, let value = try? JSONDecoder().decode(RemoteJSON.self, from: data), value.list.count == 5 else { continue }
                    let values = value.list
                    guard values[2].text == topic else { continue }
                    if values[3].text == "postgres_changes" || (values[3].text == "phx_reply" && values[4]["status"].text == "ok") { await changed() }
                } catch { return } // The foreground reconciliation timer also covers socket loss.
            }
        }
        heartbeatTask = Task {
            var sequence = 2
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(25))
                    let heartbeat = RemoteJSON.array([.null, .string(String(sequence)), .string("phoenix"), .string("heartbeat"), .object([:])])
                    try await socket.send(.data(JSONEncoder().encode(heartbeat))); sequence += 1
                } catch { return }
            }
        }
    }
    public func disconnect() {
        receiveTask?.cancel(); heartbeatTask?.cancel()
        socket?.cancel(with: .normalClosure, reason: nil)
        receiveTask = nil; heartbeatTask = nil; socket = nil
    }
}
