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
    private func awsAPI() throws -> RemoteAPI {
        let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [StubProtocol.self]
        return RemoteAPI(configuration: try RemoteConfiguration(url: URL(string: "https://example.execute-api.us-east-1.amazonaws.com")!,
            provider: .aws, webSocketURL: URL(string: "wss://socket.execute-api.us-east-1.amazonaws.com/pilot")), transport: URLSession(configuration: c))
    }
    func testAWSConfigurationRequiresSecureKeylessEndpointsAndTicketOnlySocketURL() throws {
        let config = try RemoteConfiguration(url: URL(string: "https://api.example.test")!, provider: .aws,
            webSocketURL: URL(string: "wss://socket.example.test/pilot"))
        let socket = try RealtimeHints.awsSocketURL(configuration: config, ticket: "one-time_abc123")
        XCTAssertEqual(socket.query, "ticket=one-time_abc123")
        XCTAssertThrowsError(try RealtimeHints.awsSocketURL(configuration: config, ticket: "Bearer secret"))
        XCTAssertThrowsError(try RemoteConfiguration(url: config.url, publishableKey: "private", provider: .aws))
        XCTAssertThrowsError(try RemoteConfiguration(url: config.url, provider: .aws, webSocketURL: URL(string: "ws://socket.example.test")))
    }
    func testAWSManagedEmailOTPChallengeIsBoundToRequestedEmail() async throws {
        let api = try awsAPI(), id = user
        StubProtocol.handler = { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "apikey")); XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let body = try JSONDecoder().decode(RemoteJSON.self, from: Self.body(request))
            if request.url!.lastPathComponent == "otp" { return (200, .object(["session": .string("managed-session"), "challenge": .string("EMAIL_OTP")])) }
            XCTAssertEqual(body["session"].text, "managed-session"); XCTAssertEqual(body["challenge"].text, "EMAIL_OTP")
            return (200, self.auth(id))
        }
        try await api.sendOTP(email: "synthetic@example.test")
        do { _ = try await api.verifyOTP(email: "other@example.test", code: "123456"); XCTFail("Wrong challenge email accepted") }
        catch { XCTAssertEqual(error as? RemoteError, .authentication) }
        let result = try await api.verifyOTP(email: "synthetic@example.test", code: "123456"); XCTAssertEqual(result.userID, id)
    }
    func testAWSGuestCannotBeCreatedWithoutScopedInvitation() async throws {
        let api = try awsAPI()
        StubProtocol.handler = { request in
            let body = try JSONDecoder().decode(RemoteJSON.self, from: Self.body(request))
            XCTAssertEqual(body["invitation_token"].text, "scoped-invite"); return (200, self.auth(self.user, anonymous: true))
        }
        do { _ = try await api.guest(); XCTFail("Unrestricted guest accepted") }
        catch { XCTAssertEqual(error as? RemoteError, .configuration) }
        let guest = try await api.guest(invitationToken: "scoped-invite"); XCTAssertTrue(guest.anonymous)
    }
    func testAWSRowsIncludeExplicitTeamAndNoProviderKey() async throws {
        let api = try awsAPI(), team = UUID()
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url!.query, "team_id=\(team.uuidString.lowercased())")
            XCTAssertNil(request.value(forHTTPHeaderField: "apikey")); XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer account")
            return (200, .array([]))
        }
        _ = try await api.rows("songs", token: "account", teamID: team)
    }
    private func catalogPage(team: UUID, songs: [RemoteJSON] = [], cursor: RemoteJSON = .null) -> RemoteJSON {
        .object(["schema_version": .int(1), "team_id": .id(team), "next_cursor": cursor,
            "songs": .array(songs), "chart_versions": .array([]), "assets": .array([]),
            "setlists": .array([]), "performance_items": .array([]), "personal_preferences": .array([])])
    }
    private func catalogCursor(team: UUID, scope: String = String(repeating: "a", count: 64)) -> RemoteJSON {
        .object(["schema_version": .int(1), "team_id": .id(team), "table": .string("songs"),
            "after_key": .id(UUID()), "scope_token": .string(scope)])
    }
    func testAWSCatalogUsesOneRequestWithExactSelectedTeam() async throws {
        let api = try awsAPI(), team = UUID()
        nonisolated(unsafe) var requests = 0
        StubProtocol.handler = { request in
            requests += 1
            XCTAssertEqual(request.httpMethod, "POST"); XCTAssertEqual(request.url!.path, "/rest/v1/rpc/get_team_catalog_page")
            XCTAssertNil(request.value(forHTTPHeaderField: "apikey")); XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer account")
            let body = try JSONDecoder().decode(RemoteJSON.self, from: Self.body(request))
            XCTAssertEqual(body["p"], .object(["team_id": .id(team), "selected_team_id": .id(team), "limit": .int(100)]))
            return (200, self.catalogPage(team: team))
        }
        let result = try await api.teamCatalog(token: "account", teamID: team)
        XCTAssertEqual(result["songs"], .array([])); XCTAssertEqual(requests, 1)
    }
    func testAWSCatalogForwardsOpaqueCursorAndAcceptsEmptyAdvancingPage() async throws {
        let api = try awsAPI(), team = UUID(), first = catalogCursor(team: team), second = catalogCursor(team: team)
        let song: RemoteJSON = .object(["id": .id(UUID()), "title": .string("Synthetic chart")])
        nonisolated(unsafe) var requests = 0
        StubProtocol.handler = { request in
            let payload = try JSONDecoder().decode(RemoteJSON.self, from: Self.body(request))["p"]
            requests += 1
            switch requests {
            case 1: XCTAssertEqual(payload["cursor"], .null); return (200, self.catalogPage(team: team, songs: [song], cursor: first))
            case 2: XCTAssertEqual(payload["cursor"], first); return (200, self.catalogPage(team: team, cursor: second))
            default: XCTAssertEqual(payload["cursor"], second); return (200, self.catalogPage(team: team, songs: [song]))
            }
        }
        let result = try await api.teamCatalog(token: "account", teamID: team)
        XCTAssertEqual(result["songs"], .array([song, song])); XCTAssertEqual(requests, 3)
    }
    func testAWSCatalogAssemblesMoreThanFourMiBAcrossBoundedPages() async throws {
        let api = try awsAPI(), team = UUID()
        let rows = (0..<10).map { RemoteJSON.object(["id": .id(UUID()), "title": .string("Synthetic \($0)"), "test_padding": .string(String(repeating: "x", count: 48_000))]) }
        nonisolated(unsafe) var requests = 0
        StubProtocol.handler = { _ in
            requests += 1
            let page = self.catalogPage(team: team, songs: rows, cursor: requests < 10 ? self.catalogCursor(team: team) : .null)
            XCTAssertLessThan(try JSONEncoder().encode(page).count, 512 * 1024)
            return (200, page)
        }
        let result = try await api.teamCatalog(token: "account", teamID: team)
        XCTAssertEqual(result["songs"].list.count, 100)
        XCTAssertGreaterThan(try JSONEncoder().encode(result).count, 4 * 1024 * 1024)
    }
    func testAWSCatalogRejectsCursorLoopForeignScopeAndOversizedPage() async throws {
        let api = try awsAPI(), team = UUID(), cursor = catalogCursor(team: team)
        let badPages = [catalogPage(team: team, cursor: cursor),
            catalogPage(team: UUID()), catalogPage(team: team, cursor: catalogCursor(team: UUID())),
            catalogPage(team: team, cursor: catalogCursor(team: team, scope: String(repeating: "b", count: 64))),
            catalogPage(team: team, songs: Array(repeating: .null, count: 101)),
            catalogPage(team: team, cursor: .object(["after_key": .string("raw-private-key")]))]
        for bad in badPages {
            nonisolated(unsafe) var requests = 0
            StubProtocol.handler = { _ in
                requests += 1
                return (200, requests == 1 ? self.catalogPage(team: team, cursor: cursor) : bad)
            }
            do { _ = try await api.teamCatalog(token: "account", teamID: team); XCTFail("Invalid continuation accepted") }
            catch { XCTAssertEqual(error as? RemoteError, .invalidResponse) }
            XCTAssertEqual(requests, 2)
        }
    }
    func testAWSCatalogNeverReturnsPartialRowsAfterLaterFailure() async throws {
        let api = try awsAPI(), team = UUID()
        for status in [403, 409, 503] {
            nonisolated(unsafe) var requests = 0
            StubProtocol.handler = { _ in
                requests += 1
                if requests == 1 { return (200, self.catalogPage(team: team, songs: [.object(["id": .id(UUID())])], cursor: self.catalogCursor(team: team))) }
                return (status, .object(["message": .string(status == 409 ? "CATALOG_CHANGED" : "failed")]))
            }
            do { _ = try await api.teamCatalog(token: "account", teamID: team); XCTFail("Partial rows returned") }
            catch { XCTAssertEqual(error as? RemoteError, status == 403 ? .forbidden : status == 409 ? .conflict : .unavailable) }
        }
    }
    func testAWSCatalogRejectsIncompletePayloadInsteadOfClearingCachedRows() async throws {
        let api = try awsAPI()
        let invalid: [RemoteJSON] = [.array([]), .object(["songs": .array([])]),
            .object(["songs": .array([]), "chart_versions": .array([]), "assets": .array([]), "setlists": .array([]),
                "performance_items": .array([]), "personal_preferences": .null])]
        for value in invalid {
            StubProtocol.handler = { _ in (200, value) }
            do { _ = try await api.teamCatalog(token: "account", teamID: UUID()); XCTFail("Incomplete catalog accepted") }
            catch { XCTAssertEqual(error as? RemoteError, .invalidResponse) }
        }
    }
    func testAWSSignedUploadNeverLeaksAccountCredentialsToS3() async throws {
        let api = try awsAPI()
        StubProtocol.handler = { request in
            if request.url!.host!.contains("execute-api") {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer account")
                let body = try JSONDecoder().decode(RemoteJSON.self, from: Self.body(request))
                XCTAssertEqual(body["key"].text, "team/asset.pdf"); XCTAssertEqual(body["bytes"].integer, 3)
                return (200, .object(["url": .string("https://bucket.s3.us-east-1.amazonaws.com/team/asset.pdf?X-Amz-Signature=signed"), "headers": .object(["If-None-Match": .string("*"), "x-amz-checksum-sha256": .string("synthetic-checksum"), "Content-Type": .string("application/pdf")])]))
            }
            XCTAssertEqual(request.httpMethod, "PUT"); XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "apikey")); XCTAssertEqual(Self.body(request), Data([1, 2, 3]))
            XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "*"); XCTAssertEqual(request.value(forHTTPHeaderField: "x-amz-checksum-sha256"), "synthetic-checksum")
            return (200, .null)
        }
        try await api.upload(key: "team/asset.pdf", bytes: Data([1, 2, 3]), type: "application/pdf", token: "account")
    }
    func testAWSSignedAssetURLRejectsOtherHostsAndInsecureURLs() async throws {
        let api = try awsAPI()
        for url in ["http://bucket.s3.us-east-1.amazonaws.com/a?X-Amz-Signature=x", "https://evil.example/a?X-Amz-Signature=x", "https://s3.us-east-1.amazonaws.com.evil.example/a?X-Amz-Signature=x", "https://user:secret@bucket.s3.us-east-1.amazonaws.com/a?X-Amz-Signature=x"] {
            StubProtocol.handler = { request in
                XCTAssertTrue(request.url!.host!.contains("execute-api")); return (200, .object(["url": .string(url)]))
            }
            do { try await api.upload(key: "team/a", bytes: Data([1]), type: "application/pdf", token: "account"); XCTFail("Unsafe signed URL accepted") }
            catch { XCTAssertEqual(error as? RemoteError, .configuration) }
        }
    }

    func testAWSSignedDownloadNeverLeaksCredentialsAndStillBoundsBytes() async throws {
        let api = try awsAPI(), drawing = RemoteJSON.string("synthetic archive")
        StubProtocol.handler = { request in
            if request.url!.host!.contains("execute-api") {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer account")
                return (200, .object(["url": .string("https://bucket.s3.us-east-1.amazonaws.com/team/archive?X-Amz-Signature=signed")]))
            }
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization")); XCTAssertNil(request.value(forHTTPHeaderField: "apikey"))
            return (200, drawing)
        }
        let data = try await api.download(key: "team/archive", token: "account", maximumBytes: 1024)
        XCTAssertEqual(data, try JSONEncoder().encode(drawing))
        do { _ = try await api.download(key: "team/archive", token: "account", maximumBytes: 2); XCTFail("Oversized archive accepted") }
        catch { XCTAssertEqual(error as? RemoteError, .tooLarge) }
    }
    func testAWSSignedUploadRejectsCredentialHeaders() async throws {
        let api = try awsAPI()
        StubProtocol.handler = { _ in (200, .object(["url": .string("https://bucket.s3.us-east-1.amazonaws.com/team/archive?X-Amz-Signature=signed"), "headers": .object(["Authorization": .string("private")])])) }
        do { try await api.upload(key: "team/archive", bytes: Data([1]), type: "application/pdf", token: "account"); XCTFail("Credential header accepted") }
        catch { XCTAssertEqual(error as? RemoteError, .invalidResponse) }
    }

    func testRealtimeFailureBackoffIsBoundedAndResetsAfterRecovery() {
        let now = Date(timeIntervalSince1970: 1_000), next = now.addingTimeInterval(1)
        var retry = RealtimeRetryPolicy()
        XCTAssertTrue(retry.permitsAttempt(at: now))
        retry.failed(at: now, jitter: 1)
        XCTAssertFalse(retry.permitsAttempt(at: now)); XCTAssertTrue(retry.permitsAttempt(at: next))
        for _ in 0..<20 { retry.failed(at: now, jitter: 1.2) }
        XCTAssertLessThanOrEqual(retry.retryAt.timeIntervalSince(now), 60)
        XCTAssertTrue(retry.permitsAttempt(at: now.addingTimeInterval(60)))
        retry.succeeded(); XCTAssertEqual(retry.failures, 0); XCTAssertTrue(retry.permitsAttempt(at: now))
    }
    func testCatalogFallbackWaitsSixtySecondsWithoutDelayingLivePolls() {
        var schedule = CatalogRefreshSchedule()
        XCTAssertTrue(schedule.isDue(at: 1_000)); schedule.refreshed(at: 1_000)
        for time in [1_015.0, 1_030.0, 1_045.0, 1_059.9] { XCTAssertFalse(schedule.isDue(at: time)) }
        XCTAssertTrue(schedule.isDue(at: 1_060)); schedule.refreshed(at: 1_060)
        XCTAssertFalse(schedule.isDue(at: 1_075)); XCTAssertTrue(schedule.isDue(at: 1_120))
        schedule.reset(); XCTAssertTrue(schedule.isDue(at: 1_121))
    }
    func testRealtimeFailedTicketDoesNotStormAPIAndExplicitResetObtainsFreshTicket() async throws {
        let api = try awsAPI(), hints = RealtimeHints(), team = UUID()
        nonisolated(unsafe) var attempts = 0
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url!.path, "/functions/v1/realtime-ticket")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), attempts == 0 ? "Bearer first" : "Bearer refreshed")
            attempts += 1; return (503, .null)
        }
        do { try await hints.connect(api: api, token: "first", teamID: team, sessionID: nil, changed: {}); XCTFail("Ticket failure accepted") }
        catch { XCTAssertEqual(error as? RemoteError, .unavailable) }
        do { try await hints.connect(api: api, token: "refreshed", teamID: team, sessionID: nil, changed: {}); XCTFail("Immediate retry accepted") }
        catch { XCTAssertEqual(error as? RemoteError, .unavailable) }
        XCTAssertEqual(attempts, 1)
        await hints.disconnect()
        do { try await hints.connect(api: api, token: "refreshed", teamID: team, sessionID: nil, changed: {}); XCTFail("Ticket failure accepted") }
        catch { XCTAssertEqual(error as? RemoteError, .unavailable) }
        XCTAssertEqual(attempts, 2); let connected = await hints.connected; XCTAssertFalse(connected)
    }

}
