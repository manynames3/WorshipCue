import Foundation
import WorshipCueCore

public enum RemoteError: Error, Equatable {
    case configuration, invalidResponse, authentication, forbidden, conflict, unavailable, tooLarge
    case server(String)
}

/// JSON stays value typed across the transport actor; server messages never become logs or UI copy.
public enum RemoteJSON: Codable, Equatable, Sendable {
    case object([String: RemoteJSON]), array([RemoteJSON]), string(String), number(Double), bool(Bool), null
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self), v.isFinite { self = .number(v) }
        else if let v = try? c.decode([RemoteJSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: RemoteJSON].self)) }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public subscript(_ key: String) -> RemoteJSON { if case .object(let v) = self { return v[key] ?? .null }; return .null }
    public var text: String? { if case .string(let v) = self { return v }; return nil }
    public var uuid: UUID? { text.flatMap(UUID.init(uuidString:)) }
    public var integer: Int64? {
        if case .number(let v) = self, v >= 0, v <= 9_007_199_254_740_991, v.rounded() == v { return Int64(v) }
        return nil
    }
    public var list: [RemoteJSON] { if case .array(let v) = self { return v }; return [] }
    public var flag: Bool { self == .bool(true) }
    public static func id(_ v: UUID) -> Self { .string(v.uuidString.lowercased()) }
    public static func int(_ v: Int64) -> Self { .number(Double(v)) }
    public func requiredID(_ key: String) throws -> UUID { guard let v = self[key].uuid else { throw RemoteError.invalidResponse }; return v }
    public func requiredText(_ key: String) throws -> String { guard let v = self[key].text, !v.isEmpty else { throw RemoteError.invalidResponse }; return v }
    public func call() throws -> LiveCall {
        guard let sequence = self["sequence"].integer else { throw RemoteError.invalidResponse }
        return try LiveCall(id: requiredID("id"), sessionID: requiredID("session_id"), sequence: sequence,
            performanceItemID: requiredID("performance_item_id"), songID: requiredID("song_id"),
            teamChartVersionID: requiredID("team_chart_version_id"), performanceKey: requiredText("performance_key"))
    }
}

public struct RemoteConfiguration: Codable, Equatable, Sendable {
    public let url: URL
    public let publishableKey: String
    public init(url: URL, publishableKey: String, allowLocalHTTP: Bool = false) throws {
        guard url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/",
              url.scheme == "https" || (allowLocalHTTP && url.scheme == "http" && ["localhost", "127.0.0.1"].contains(url.host)),
              !(url.host ?? "").isEmpty, !publishableKey.isEmpty, !publishableKey.contains(where: { $0.isWhitespace }),
              !publishableKey.hasPrefix("sb_secret_") else { throw RemoteError.configuration }
        if !publishableKey.hasPrefix("sb_publishable_") {
            let parts = publishableKey.split(separator: ".")
            guard parts.count == 3 else { throw RemoteError.configuration }
            var body = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            body += String(repeating: "=", count: (4 - body.count % 4) % 4)
            guard let data = Data(base64Encoded: body), let jwt = try? JSONDecoder().decode(RemoteJSON.self, from: data),
                  jwt["role"].text == "anon" else { throw RemoteError.configuration }
        }
        self.url = url; self.publishableKey = publishableKey
    }
}

public struct RemoteSession: Codable, Equatable, Sendable {
    public let userID: UUID
    public let anonymous: Bool
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date
    public init(response: RemoteJSON, now: Date = Date()) throws {
        userID = try response["user"].requiredID("id")
        anonymous = response["user"]["is_anonymous"].flag
        accessToken = try response.requiredText("access_token")
        refreshToken = try response.requiredText("refresh_token")
        guard let seconds = response["expires_in"].integer, seconds > 0, seconds <= 604800 else { throw RemoteError.invalidResponse }
        expiresAt = now.addingTimeInterval(Double(seconds))
    }
}

public actor RemoteAPI {
    public let configuration: RemoteConfiguration
    private let transport: URLSession
    public init(configuration: RemoteConfiguration, transport: URLSession = .shared) {
        self.configuration = configuration; self.transport = transport
    }
    private func request(_ path: String, method: String, token: String?, body: Data?, type: String = "application/json") throws -> URLRequest {
        guard !path.contains(".."), !path.contains("?"), !path.contains("#"), !path.contains("\\") else { throw RemoteError.configuration }
        var r = URLRequest(url: configuration.url.appendingPathComponent(path), timeoutInterval: 30)
        r.httpMethod = method; r.httpBody = body
        r.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        r.setValue(type, forHTTPHeaderField: "Content-Type")
        r.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        return r
    }
    private func validate(_ response: URLResponse, data: Data) throws {
        guard let h = response as? HTTPURLResponse else { throw RemoteError.invalidResponse }
        guard (200..<300).contains(h.statusCode) else {
            let code = (try? JSONDecoder().decode(RemoteJSON.self, from: data))?["message"].text
            if ["REVISION_CONFLICT", "STALE_SEQUENCE", "STALE_EPOCH", "STALE_CALL", "STALE_CONTROLLER", "SESSION_ENDED", "IDEMPOTENCY_CONFLICT", "LEASE_HELD"].contains(code ?? "") { throw RemoteError.conflict }
            if ["ACCESS_REVOKED", "ASSET_NOT_AUTHORIZED"].contains(code ?? "") { throw RemoteError.forbidden }
            if ["AUTH_REQUIRED"].contains(code ?? "") { throw RemoteError.authentication }
            switch h.statusCode {
            case 401: throw RemoteError.authentication
            case 403: throw RemoteError.forbidden
            case 409: throw RemoteError.conflict
            case 429, 500...599: throw RemoteError.unavailable
            default: throw RemoteError.server("HTTP_\(h.statusCode)")
            }
        }
    }
    public func json(_ path: String, method: String = "POST", token: String? = nil, body: RemoteJSON = .object([:])) async throws -> RemoteJSON {
        let encoded = method == "GET" ? nil : try JSONEncoder().encode(body)
        let (data, response) = try await transport.data(for: request(path, method: method, token: token, body: encoded))
        guard data.count <= 4 * 1024 * 1024 else { throw RemoteError.tooLarge }
        try validate(response, data: data)
        return data.isEmpty ? .null : try JSONDecoder().decode(RemoteJSON.self, from: data)
    }
    public func rpc(_ name: String, token: String, _ payload: [String: RemoteJSON] = [:]) async throws -> RemoteJSON {
        guard name.allSatisfy({ $0.isLowercase || $0 == "_" }) else { throw RemoteError.configuration }
        return try await json("rest/v1/rpc/\(name)", token: token, body: .object(["p": .object(payload)]))
    }
    public func rows(_ table: String, token: String) async throws -> [RemoteJSON] {
        guard table.allSatisfy({ $0.isLowercase || $0 == "_" }) else { throw RemoteError.configuration }
        return try await json("rest/v1/\(table)", method: "GET", token: token).list
    }
    public func sendOTP(email: String) async throws {
        _ = try await json("auth/v1/otp", body: .object(["email": .string(email), "create_user": .bool(true)]))
    }
    public func verifyOTP(email: String, code: String) async throws -> RemoteSession {
        try await RemoteSession(response: json("auth/v1/verify", body: .object(["email": .string(email), "token": .string(code), "type": .string("email")])))
    }
    public func guest() async throws -> RemoteSession { try await RemoteSession(response: json("auth/v1/signup")) }
    public func signOut(token: String) async throws {
        var r = try request("auth/v1/logout", method: "POST", token: token, body: nil)
        var url = URLComponents(url: r.url!, resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "scope", value: "local")]; r.url = url.url; r.timeoutInterval = 5
        let (data, response) = try await transport.data(for: r); try validate(response, data: data)
    }
    public func refresh(_ value: RemoteSession) async throws -> RemoteSession {
        // The query belongs only to this fixed auth endpoint, never to caller-provided asset paths.
        var r = try request("auth/v1/token", method: "POST", token: nil, body: JSONEncoder().encode(RemoteJSON.object(["refresh_token": .string(value.refreshToken)])))
        var components = URLComponents(url: r.url!, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token")]; r.url = components.url
        let (data, response) = try await transport.data(for: r); try validate(response, data: data)
        let new = try RemoteSession(response: JSONDecoder().decode(RemoteJSON.self, from: data))
        guard new.userID == value.userID, new.anonymous == value.anonymous else { throw RemoteError.authentication }
        return new
    }
    public func upload(key: String, bytes: Data, type: String, token: String) async throws {
        try validateKey(key)
        guard !bytes.isEmpty, bytes.count <= 100 * 1024 * 1024 else { throw RemoteError.tooLarge }
        var r = try request("storage/v1/object/worshipcue-private/\(key)", method: "POST", token: token, body: bytes, type: type)
        r.setValue("false", forHTTPHeaderField: "x-upsert")
        let (data, response) = try await transport.data(for: r); try validate(response, data: data)
    }
    public func download(key: String, token: String, maximumBytes: Int) async throws -> Data {
        try validateKey(key)
        let (file, response) = try await transport.download(for: request("storage/v1/object/authenticated/worshipcue-private/\(key)", method: "GET", token: token, body: nil))
        defer { try? FileManager.default.removeItem(at: file) }
        try validate(response, data: Data())
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= maximumBytes else { throw RemoteError.tooLarge }
        return try Data(contentsOf: file, options: .mappedIfSafe)
    }
    private func validateKey(_ key: String) throws {
        guard !key.isEmpty, key.count <= 300, !key.hasPrefix("/"), !key.contains(".."),
              key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-/._".contains($0)) }) else { throw RemoteError.configuration }
    }
}
