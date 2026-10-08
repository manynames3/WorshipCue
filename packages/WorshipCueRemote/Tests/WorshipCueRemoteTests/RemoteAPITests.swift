import XCTest
import Foundation
import WorshipCueCore
@testable import WorshipCueRemote

final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, RemoteJSON))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, json) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONEncoder().encode(json))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class RemoteAPITests: XCTestCase {
    private let user = UUID()
    private func api() throws -> RemoteAPI {
        let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [StubProtocol.self]
        return RemoteAPI(configuration: try RemoteConfiguration(url: URL(string: "https://example.supabase.co")!, publishableKey: "sb_publishable_test"), transport: URLSession(configuration: c))
    }
    private static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
        return data
    }
    private func auth(_ id: UUID, anonymous: Bool = false) -> RemoteJSON {
        .object(["user": .object(["id": .id(id), "is_anonymous": .bool(anonymous)]), "access_token": .string("opaque-access"),
                 "refresh_token": .string("opaque-refresh"), "expires_in": .int(3600)])
    }
    func testConfigurationRejectsPrivilegedKeysAndInsecureOrCredentialURLs() throws {
        for value in ["http://example.com", "https://user:password@example.com", "https://example.com/path", "https://example.com?q=token"] {
            XCTAssertThrowsError(try RemoteConfiguration(url: URL(string: value)!, publishableKey: "sb_publishable_test"))
        }
        XCTAssertThrowsError(try RemoteConfiguration(url: URL(string: "https://example.com")!, publishableKey: "sb_secret_test"))
        let body = Data("{\"role\":\"service_role\"}".utf8).base64EncodedString()
        XCTAssertThrowsError(try RemoteConfiguration(url: URL(string: "https://example.com")!, publishableKey: "e30.\(body).signature"))
        XCTAssertNoThrow(try RemoteConfiguration(url: URL(string: "http://127.0.0.1:54321")!, publishableKey: "sb_publishable_test", allowLocalHTTP: true))
    }
    func testManagedOTPAndVerificationKeepCredentialsOutOfRPCBody() async throws {
        let api = try api(), id = user
        StubProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "sb_publishable_test")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let body = try JSONDecoder().decode(RemoteJSON.self, from: Self.body(request))
            XCTAssertEqual(body["email"].text, "synthetic@example.test")
            if request.url!.path.hasSuffix("otp") { XCTAssertTrue(body["create_user"].flag); return (200, .object([:])) }
            XCTAssertEqual(body["type"].text, "email"); XCTAssertEqual(body["token"].text, "123456")
            return (200, self.auth(id))
        }
        try await api.sendOTP(email: "synthetic@example.test")
        let result = try await api.verifyOTP(email: "synthetic@example.test", code: "123456")
        XCTAssertEqual(result.userID, id); XCTAssertFalse(result.anonymous)
    }
    func testGuestIdentityIsManagedAndDoesNotPretendToBeMember() async throws {
        let api = try api(), id = user
        StubProtocol.handler = { request in XCTAssertEqual(request.url!.path, "/auth/v1/signup"); return (200, self.auth(id, anonymous: true)) }
        let result = try await api.guest(); XCTAssertTrue(result.anonymous)
    }
    func testLogoutRevokesOnlyThisSessionAndHasBoundedNetworkWait() async throws {
        let api = try api()
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url!.path, "/auth/v1/logout")
            XCTAssertEqual(request.url!.query, "scope=local")
            XCTAssertEqual(request.timeoutInterval, 5)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic")
            return (204, .null)
        }
        try await api.signOut(token: "synthetic")
    }
    func testRefreshValidatesIdentityAndUsesRefreshEndpoint() async throws {
        let api = try api(), original = try RemoteSession(response: auth(user))
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url!.query, "grant_type=refresh_token")
            return (200, self.auth(UUID()))
        }
        do { _ = try await api.refresh(original); XCTFail("Identity switch accepted") }
        catch { XCTAssertEqual(error as? RemoteError, .authentication) }
    }
    func testRPCUsesAuthenticatedJSONPayloadAndPreservesCommandIdentity() async throws {
        let api = try api(), command = UUID()
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url!.path, "/rest/v1/rpc/publish_call")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer user-token")
            let body = try JSONDecoder().decode(RemoteJSON.self, from: Self.body(request))
            XCTAssertEqual(body["p"]["command_id"].uuid, command)
            XCTAssertEqual(body["p"]["expected_latest_sequence"].integer, 4)
            return (200, .object(["command_id": .id(command)]))
        }
        let receipt = try await api.rpc("publish_call", token: "user-token", ["command_id": .id(command), "expected_latest_sequence": .int(4)])
        XCTAssertEqual(receipt["command_id"].uuid, command)
    }
    func testConflictAndAuthorizationFailuresAreExplicitWithoutContent() async throws {
        let api = try api()
        for (status, expected) in [(401, RemoteError.authentication), (403, .forbidden), (409, .conflict), (503, .unavailable)] {
            StubProtocol.handler = { _ in (status, .object(["message": .string("private chart title and credentials")])) }
            do { _ = try await api.rpc("save_annotation_revision", token: "user"); XCTFail("Error accepted") }
            catch { XCTAssertEqual(error as? RemoteError, expected) }
        }
    }
    func testPathsRejectTraversalBeforeSendingCredentials() async throws {
        let api = try api()
        StubProtocol.handler = { _ in XCTFail("Unsafe request transmitted"); return (200, .null) }
        for key in ["../other/ink", "/tenant/file", "tenant/%2e%2e/file", "https://other.test/file"] {
            do { try await api.upload(key: key, bytes: Data([1]), type: "application/octet-stream", token: "private"); XCTFail("Unsafe key accepted") }
            catch { XCTAssertEqual(error as? RemoteError, .configuration) }
        }
    }
    func testPrivateDownloadBoundsBytesAndUsesAuthenticatedStoragePath() async throws {
        let api = try api(), value = RemoteJSON.string("synthetic drawing bytes")
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url!.path, "/storage/v1/object/authenticated/worshipcue-private/synthetic/test.drawing")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic")
            return (200, value)
        }
        let data = try await api.download(key: "synthetic/test.drawing", token: "synthetic", maximumBytes: 1024)
        XCTAssertEqual(data, try JSONEncoder().encode(value))
        do { _ = try await api.download(key: "synthetic/test.drawing", token: "synthetic", maximumBytes: 2); XCTFail("Oversized download accepted") }
        catch { XCTAssertEqual(error as? RemoteError, .tooLarge) }
    }
    func testSQLFailuresAtHTTP400KeepFencingAndRevocationMeaning() async throws {
        let api = try api()
        for (code, expected) in [("STALE_CONTROLLER", RemoteError.conflict), ("STALE_CALL", .conflict), ("ACCESS_REVOKED", .forbidden), ("ASSET_NOT_AUTHORIZED", .forbidden)] {
            StubProtocol.handler = { _ in (400, .object(["code": .string("P0001"), "message": .string(code)])) }
            do { _ = try await api.rpc("publish_call", token: "synthetic"); XCTFail("RPC failure accepted") }
            catch { XCTAssertEqual(error as? RemoteError, expected) }
        }
    }
    func testDurableSnapshotCallDecoderRejectsInvalidSequencesAndKeys() throws {
        let s = UUID(), song = UUID(), chart = UUID(), item = UUID()
        var json: [String: RemoteJSON] = ["id": .id(UUID()), "session_id": .id(s), "song_id": .id(song), "team_chart_version_id": .id(chart),
            "performance_item_id": .id(item), "sequence": .int(1), "performance_key": .string("G")]
        let call = try RemoteJSON.object(json).call()
        var state = LiveState(sessionID: s)
        XCTAssertTrue(try state.receive(call)); XCTAssertNil(state.displayed)
        json["sequence"] = .int(0); XCTAssertThrowsError(try RemoteJSON.object(json).call())
        json["sequence"] = .int(1); json["performance_key"] = .string("invalid"); XCTAssertThrowsError(try RemoteJSON.object(json).call())
    }
}
