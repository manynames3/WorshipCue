import XCTest
import Foundation
import SwiftUI
import WorshipCueRemote
@testable import WorshipCue

/// Actual native administration/vault behavior over a synthetic, isolated HTTP transport.
/// These tests do not use a normal account, hosted AWS, or a second physical iPad.
final class AdministrationTestProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fixtures: [String: AdministrationFixture] = [:]
    static func register(_ fixture: AdministrationFixture, host: String) { lock.withLock { fixtures[host] = fixture } }
    static func unregister(host: String) { _ = lock.withLock { fixtures.removeValue(forKey: host) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let host = request.url?.host, host.hasSuffix(".invalid"),
              let fixture = Self.lock.withLock({ Self.fixtures[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        fixture.respond(request) { [weak self] reply in
            guard let self else { return }
            if let code = reply.failure { client?.urlProtocol(self, didFailWithError: URLError(code)); return }
            guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: reply.status,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"]),
                let bytes = try? JSONEncoder().encode(reply.value) else {
                client?.urlProtocol(self, didFailWithError: URLError(.cannotParseResponse)); return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: bytes); client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

struct AdministrationReply {
    var status = 200
    var value: TeamJSON = .null
    var failure: URLError.Code?
}

final class AdministrationFixture: @unchecked Sendable {
    static let user = UUID(uuidString: "81000000-0000-0000-0000-000000000001")!
    static let other = UUID(uuidString: "81000000-0000-0000-0000-000000000002")!
    static let church = UUID(uuidString: "82000000-0000-0000-0000-000000000001")!
    static let teamA = UUID(uuidString: "83000000-0000-0000-0000-000000000001")!
    static let teamB = UUID(uuidString: "83000000-0000-0000-0000-000000000002")!
    static let invite = UUID(uuidString: "84000000-0000-0000-0000-000000000001")!
    private let lock = NSLock()
    private var requests: [(String, TeamJSON)] = []
    private var receipts: [UUID: TeamJSON] = [:]
    private var selfRole = "admin", otherRole = "member", selfName = "Synthetic administrator"
    private var selfRevision: Int64 = 1, otherRevision: Int64 = 1
    private var timeoutAfterCommit: String?, pausedName: String?
    private var waiting: [(AdministrationReply, (AdministrationReply) -> Void)] = []
    private var malformedRoster: TeamJSON?, malformedInvitations: TeamJSON?
    private var malformedMutationReceipt: TeamJSON?
    private var mutations = 0
    private var failLaterExport = false

    func denyLaterExportPage(_ value: Bool) { lock.withLock { failLaterExport = value } }
    func timeoutNextCommitted(_ name: String) { lock.withLock { timeoutAfterCommit = name } }
    func pauseNext(_ name: String) { lock.withLock { pausedName = name } }
    func overrideRoster(_ value: TeamJSON?) { lock.withLock { malformedRoster = value } }
    func overrideInvitations(_ value: TeamJSON?) { lock.withLock { malformedInvitations = value } }
    func overrideNextMutationReceipt(_ value: TeamJSON) { lock.withLock { malformedMutationReceipt = value } }
    func changeServerName(_ name: String) { lock.withLock { selfName = name; selfRevision += 1 } }
    var isPaused: Bool { lock.withLock { !waiting.isEmpty } }
    var mutationCount: Int { lock.withLock { mutations } }
    func recorded(_ name: String) -> [TeamJSON] { lock.withLock { requests.filter { $0.0 == name }.map(\.1) } }
    func release() {
        let callbacks = lock.withLock { let value = waiting; waiting = []; return value }
        for (value, callback) in callbacks { callback(value) }
    }
    static func membership(_ user: UUID = user, team: UUID = teamA, role: String = "admin",
                           revision: Int64 = 1, name: String = "Synthetic administrator") -> TeamJSON {
        .object(["id": .id(user), "user_id": .id(user), "church_id": .id(church), "team_id": .id(team),
            "role": .string(role), "active": .bool(true), "display_name": .string(name), "revision": .int(revision)])
    }
    private func roster(_ team: UUID) -> TeamJSON {
        .object(["team_id": .id(team), "members": .array([
            Self.membership(team: team, role: team == Self.teamA ? selfRole : "admin",
                revision: team == Self.teamA ? selfRevision : 1, name: team == Self.teamA ? selfName : "Other team administrator"),
            Self.membership(Self.other, team: team, role: team == Self.teamA ? otherRole : "member",
                revision: team == Self.teamA ? otherRevision : 1, name: "Synthetic musician")])])
    }
    static func invitation(team: UUID = teamA) -> TeamJSON {
        .object(["id": .id(invite), "invitation_id": .id(invite), "team_id": .id(team), "church_id": .id(church),
            "permitted_role": .string("member"), "setlist_id": .null, "expires_at": .string("2026-12-01T00:00:00Z"),
            "max_uses": .int(10), "used_count": .int(0), "revoked_at": .null,
            "created_at": .string("2026-10-08T00:00:00Z"), "revision": .int(1), "status": .string("active")])
    }
    private static func bytes(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var value = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }; value.append(contentsOf: buffer.prefix(count))
        }
        return value
    }
    func respond(_ request: URLRequest, completion: @escaping (AdministrationReply) -> Void) {
        let name = request.url?.lastPathComponent ?? "", body = (try? JSONDecoder().decode(TeamJSON.self, from: Self.bytes(request))) ?? .null
        let payload = body["p"]
        lock.lock(); requests.append((name, payload))
        var reply = AdministrationReply()
        let team = payload["team_id"].uuid ?? Self.teamA
        switch name {
        case "get_account_preflight":
            reply.value = .object(["schema_version": .int(1), "owner_user_id": .id(Self.user), "generated_at": .string("2026-10-08T12:00:00Z"),
                "delete_supported": .bool(false), "unavailable_team_count": .int(0), "teams": .array([Self.teamA, Self.teamB].map { id in
                    .object(["team_id": .id(id), "church_id": .id(Self.church), "display_name": .string("Synthetic team"), "role": .string("admin"),
                        "revision": .int(1), "sole_admin": .bool(true), "handoff_required": .bool(true)])
                })])
        case "get_account_export_page":
            if payload["cursor"] != .null, failLaterExport {
                reply.status = 403; reply.value = .object(["message": .string("ACCESS_REVOKED")])
            } else {
                var fields = Dictionary(uniqueKeysWithValues: AccountDataExport.tables.map { ($0, TeamJSON.array([])) })
                fields["schema_version"] = .int(1); fields["owner_user_id"] = .id(Self.user); fields["team_id"] = .id(team)
                fields["export_scope"] = .string("current_authorized_team")
                if payload["cursor"] == .null {
                    fields["memberships"] = .array([Self.membership(team: team)])
                    fields["next_cursor"] = .object(["schema_version": .int(1), "team_id": .id(team), "table": .string("chat_messages"),
                        "after_key": .id(Self.invite), "scope_token": .string(String(repeating: "a", count: 64))])
                } else {
                    fields["chat_messages"] = .array([.object(["id": .id(UUID()), "team_id": .id(team), "author_id": .id(Self.user), "body": .string("Synthetic own record")])])
                    fields["next_cursor"] = .null
                }
                reply.value = .object(fields)
            }
        case "otp": reply.value = .object(["session": .string("synthetic-challenge"), "challenge": .string("EMAIL_OTP")])
        case "verify", "token":
            reply.value = .object(["user": .object(["id": .id(Self.user), "is_anonymous": .bool(false)]),
                "access_token": .string("synthetic-access"), "refresh_token": .string("synthetic-refresh"), "expires_in": .int(3600)])
        case "memberships":
            reply.value = .array([Self.membership(role: selfRole, revision: selfRevision, name: selfName), Self.membership(team: Self.teamB)])
        case "get_team_catalog", "get_team_catalog_page":
            reply.value = .object(["team_id": .id(team), "schema_version": .int(1), "next_cursor": .null, "songs": .array([]), "chart_versions": .array([]), "assets": .array([]),
                "setlists": .array([]), "performance_items": .array([]), "personal_preferences": .array([])])
        case "get_chat_rooms":
            reply.value = .object(["team_id": .id(team), "rooms": .array([]), "has_more": .bool(false),
                "blocked_author_ids": .array([]), "block_revision": .int(0)])
        case "get_team_roster": reply.value = malformedRoster ?? roster(team)
        case "get_team_invitations":
            reply.value = malformedInvitations ?? .object(["team_id": .id(team), "invitations": .array([Self.invitation(team: team)]),
                "has_more": .bool(false), "next_invitation_id": .null])
        case "set_member_display_name", "set_member_role", "set_membership_active", "handoff_team_admin", "revoke_invitation":
            guard let command = payload["command_id"].uuid else {
                lock.unlock(); completion(AdministrationReply(status: 400, value: .object(["message": .string("INVALID_INPUT")]))); return
            }
            if let receipt = receipts[command] { reply.value = receipt }
            else if team != Self.teamA {
                reply = AdministrationReply(status: 403, value: .object(["message": .string("ACCESS_REVOKED")]))
            } else {
                switch name {
                case "set_member_display_name":
                    if payload["expected_revision"].integer != selfRevision { reply.status = 409 }
                    else { selfName = payload["display_name"].text ?? ""; selfRevision += 1; reply.value = Self.membership(role: selfRole, revision: selfRevision, name: selfName) }
                case "handoff_team_admin":
                    if payload["expected_self_revision"].integer != selfRevision || payload["expected_member_revision"].integer != otherRevision { reply.status = 409 }
                    else { selfRole = "leader"; otherRole = "admin"; selfRevision += 1; otherRevision += 1; reply.value = roster(team) }
                case "set_member_role":
                    otherRole = payload["role"].text ?? "member"; otherRevision += 1
                    reply.value = Self.membership(Self.other, role: otherRole, revision: otherRevision, name: "Synthetic musician")
                case "set_membership_active":
                    var fields = ["id": TeamJSON.id(Self.other), "user_id": .id(Self.other), "church_id": .id(Self.church),
                        "team_id": .id(team), "role": .string(otherRole), "active": payload["active"], "revision": .int(otherRevision + 1), "display_name": .string("Synthetic musician")]
                    fields["active"] = payload["active"]; reply.value = .object(fields)
                default: reply.value = .object(["invitation_id": .id(Self.invite), "team_id": .id(team), "revoked": .bool(true), "revision": .int(2)])
                }
                if reply.status == 200 {
                    mutations += 1; receipts[command] = reply.value
                    if timeoutAfterCommit == name { timeoutAfterCommit = nil; reply.failure = .timedOut }
                } else { reply.value = .object(["message": .string("REVISION_CONFLICT")]) }
            }
        default: reply.value = .null
        }
        if ["set_member_display_name", "set_member_role", "set_membership_active", "handoff_team_admin", "revoke_invitation"].contains(name),
           reply.status == 200, let value = malformedMutationReceipt {
            reply.value = value; malformedMutationReceipt = nil
        }
        if pausedName == name {
            pausedName = nil; waiting.append((reply, completion)); lock.unlock(); return
        }
        lock.unlock(); completion(reply)
    }
}

@MainActor func makeAdministrationWorkspace(for testcase: XCTestCase) async throws -> (TeamWorkspace, AdministrationFixture, URL, RemoteConfiguration, URLSession) {
        let fixture = AdministrationFixture(), host = "administration-\(UUID().uuidString.lowercased()).invalid"
        AdministrationTestProtocol.register(fixture, host: host)
        let settings = URLSessionConfiguration.ephemeral; settings.protocolClasses = [AdministrationTestProtocol.self]
        let transport = URLSession(configuration: settings)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AdministrationTests-" + UUID().uuidString)
        let configuration = try RemoteConfiguration(url: URL(string: "https://" + host)!, provider: .aws)
        let team = TeamWorkspace(testRoot: root, configuration: configuration, transport: transport, realtimeEnabled: false)
        testcase.addTeardownBlock { @MainActor in
            fixture.release(); team.suspend(); _ = await team.logout(); transport.invalidateAndCancel()
            AdministrationTestProtocol.unregister(host: host); try? FileManager.default.removeItem(at: root)
        }
        let codeSent = await team.sendCode("synthetic@example.test"); XCTAssertTrue(codeSent)
        let signedIn = await team.signIn("synthetic@example.test", code: "123456"); XCTAssertTrue(signedIn)
        XCTAssertEqual(team.selectedTeam, AdministrationFixture.teamA); XCTAssertTrue(team.canAdmin)
        return (team, fixture, root, configuration, transport)
}

@MainActor final class TeamAdministrationTests: XCTestCase {
    private func setup() async throws -> (TeamWorkspace, AdministrationFixture, URL, RemoteConfiguration, URLSession) {
        try await makeAdministrationWorkspace(for: self)
    }
    private func waitPaused(_ fixture: AdministrationFixture) async throws {
        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        while !fixture.isPaused, ContinuousClock().now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(fixture.isPaused); if !fixture.isPaused { throw RemoteError.unavailable }
    }
    private func requestFile(_ team: TeamWorkspace) throws -> URL {
        try team.operationDirectory().appendingPathComponent("pending-administration.json")
    }

    func testTimeoutAfterCommitReopenRetainsFrozenCommandAndExplicitRetryOnly() async throws {
        let (team, fixture, root, configuration, transport) = try await setup()
        let model = TeamAdministration(team: team); await model.refresh()
        fixture.timeoutNextCommitted("set_member_display_name")
        await model.submit("set_member_display_name", ["expected_revision": .int(1), "display_name": .string("Prepared musician")])
        let request = try XCTUnwrap(model.pending), saved = try Data(contentsOf: requestFile(team))
        XCTAssertTrue(model.pendingFileExists); XCTAssertEqual(fixture.mutationCount, 1)
        let restored = TeamWorkspace(testRoot: root, configuration: configuration, transport: transport, realtimeEnabled: false)
        addTeardownBlock { @MainActor in restored.suspend(); _ = await restored.logout() }
        await restored.restore(); let reopened = TeamAdministration(team: restored); await reopened.refresh()
        XCTAssertEqual(reopened.pending, request); XCTAssertEqual(try Data(contentsOf: requestFile(restored)), saved)
        XCTAssertEqual(fixture.recorded("set_member_display_name").count, 1, "Restore and refresh cannot replay an uncertain operation")
        await reopened.retry()
        let calls = fixture.recorded("set_member_display_name"); XCTAssertEqual(calls.count, 2); XCTAssertEqual(calls[0], calls[1])
        XCTAssertEqual(calls[1]["expected_revision"].integer, 1, "A retry cannot substitute the refreshed server revision")
        XCTAssertEqual(fixture.mutationCount, 1); XCTAssertNil(reopened.pending); XCTAssertFalse(reopened.pendingFileExists)
        XCTAssertEqual(reopened.ownMember?["display_name"].text, "Prepared musician")
    }

    func testCorruptSavedRequestIsNeverOverwrittenOrAutomaticallySent() async throws {
        let (team, fixture, _, _, _) = try await setup(); let file = try requestFile(team)
        let corrupt = Data("{not valid JSON".utf8); try corrupt.write(to: file, options: .atomic)
        let model = TeamAdministration(team: team); await model.refresh()
        XCTAssertTrue(model.pendingFileExists); XCTAssertTrue(model.blocked); XCTAssertNotNil(model.error)
        await model.submit("set_member_display_name", ["expected_revision": .int(1), "display_name": .string("Must not replace")])
        await model.retry()
        XCTAssertEqual(try Data(contentsOf: file), corrupt); XCTAssertTrue(fixture.recorded("set_member_display_name").isEmpty)
        model.discard(); XCTAssertFalse(FileManager.default.fileExists(atPath: file.path)); XCTAssertFalse(model.pendingFileExists)
    }

    func testForeignTeamSavedRequestCannotReplayFromCurrentPartition() async throws {
        let (team, fixture, _, _, _) = try await setup()
        let request = TeamAdminRequest(name: "set_member_role", payload: ["team_id": .id(AdministrationFixture.teamB),
            "command_id": .id(UUID()), "user_id": .id(AdministrationFixture.other), "role": .string("leader"), "expected_revision": .int(1)])
        let bytes = try JSONEncoder().encode(request), file = try requestFile(team); try bytes.write(to: file, options: .atomic)
        let model = TeamAdministration(team: team); await model.refresh(); await model.retry()
        XCTAssertTrue(model.pendingFileExists); XCTAssertNotNil(model.error)
        XCTAssertTrue(fixture.recorded("set_member_role").isEmpty); XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testMalformedMutationAcknowledgementRetainsExactCommittedRequestForRetry() async throws {
        let (team, fixture, _, _, _) = try await setup(); let model = TeamAdministration(team: team); await model.refresh()
        fixture.overrideNextMutationReceipt(.null)
        await model.submit("set_member_display_name", ["expected_revision": .int(1), "display_name": .string("Committed despite bad acknowledgement")])
        let frozen = try XCTUnwrap(model.pending); XCTAssertTrue(model.pendingFileExists); XCTAssertNotNil(model.error)
        XCTAssertEqual(fixture.mutationCount, 1); await model.retry()
        XCTAssertNil(model.pending); XCTAssertFalse(model.pendingFileExists); XCTAssertEqual(fixture.mutationCount, 1)
        let calls = fixture.recorded("set_member_display_name"); XCTAssertEqual(calls.count, 2); XCTAssertEqual(calls[0], calls[1])
        XCTAssertEqual(calls[1]["command_id"].uuid, frozen.payload["command_id"]?.uuid)
    }

    func testLateRosterCannotEnterAnotherTeamsAdministrationState() async throws {
        let (team, fixture, _, _, _) = try await setup(); let model = TeamAdministration(team: team)
        fixture.pauseNext("get_team_roster"); let first = Task { await model.refresh() }; try await waitPaused(fixture)
        await team.chooseWorkspace(AdministrationFixture.membership(team: AdministrationFixture.teamB)); model.reset()
        await model.refresh(); let current = model.members
        XCTAssertFalse(current.isEmpty); XCTAssertTrue(current.allSatisfy { $0["team_id"].uuid == AdministrationFixture.teamB })
        fixture.release(); await first.value
        XCTAssertEqual(model.members, current); XCTAssertNil(model.error); XCTAssertFalse(model.busy)
    }

    func testLateCommittedMutationCannotDeleteNewTeamsPendingRequest() async throws {
        let (team, fixture, _, _, _) = try await setup(); let model = TeamAdministration(team: team); await model.refresh()
        fixture.pauseNext("set_member_display_name")
        let first = Task { await model.submit("set_member_display_name", ["expected_revision": .int(1), "display_name": .string("Old team request")]) }
        try await waitPaused(fixture); let oldFile = try requestFile(team)
        await team.chooseWorkspace(AdministrationFixture.membership(team: AdministrationFixture.teamB)); model.reset()
        let newFile = try requestFile(team), replacement = TeamAdminRequest(name: "set_member_display_name", payload: [
            "team_id": .id(AdministrationFixture.teamB), "command_id": .id(UUID()), "expected_revision": .int(1), "display_name": .string("New team request")])
        let bytes = try JSONEncoder().encode(replacement); try bytes.write(to: newFile, options: .atomic); await model.refresh()
        fixture.release(); await first.value
        XCTAssertEqual(team.selectedTeam, AdministrationFixture.teamB); XCTAssertEqual(model.pending, replacement)
        XCTAssertEqual(try Data(contentsOf: newFile), bytes); XCTAssertTrue(FileManager.default.fileExists(atPath: oldFile.path))
        XCTAssertEqual(fixture.recorded("set_member_display_name").count, 1); XCTAssertNil(model.error)
    }

    func testHandoffRefreshesOwnRoleBeforeAdminOnlyInvitationRead() async throws {
        let (team, fixture, _, _, _) = try await setup(); let model = TeamAdministration(team: team); await model.refresh()
        let priorInvitations = fixture.recorded("get_team_invitations").count
        await model.submit("handoff_team_admin", ["user_id": .id(AdministrationFixture.other), "expected_self_revision": .int(1), "expected_member_revision": .int(1)])
        XCTAssertFalse(team.canAdmin); XCTAssertTrue(team.canLead); XCTAssertEqual(model.ownMember?["role"].text, "leader")
        XCTAssertTrue(model.invitations.isEmpty); XCTAssertEqual(fixture.recorded("get_team_invitations").count, priorInvitations)
        XCTAssertEqual(fixture.recorded("get_team_roster").last?["include_inactive"].flag, false)
        XCTAssertNil(model.pending); XCTAssertFalse(model.pendingFileExists)
    }

    func testUncertainHandoffReceiptCanBeRetriedAfterLocalSelfDemotion() async throws {
        let (team, fixture, root, configuration, transport) = try await setup(); let model = TeamAdministration(team: team); await model.refresh()
        fixture.timeoutNextCommitted("handoff_team_admin")
        await model.submit("handoff_team_admin", ["user_id": .id(AdministrationFixture.other), "expected_self_revision": .int(1), "expected_member_revision": .int(1)])
        let frozen = try XCTUnwrap(model.pending)
        let restored = TeamWorkspace(testRoot: root, configuration: configuration, transport: transport, realtimeEnabled: false)
        addTeardownBlock { @MainActor in restored.suspend(); _ = await restored.logout() }
        await restored.restore(); XCTAssertFalse(restored.canAdmin)
        let reopened = TeamAdministration(team: restored); await reopened.refresh(); XCTAssertEqual(reopened.pending, frozen)
        await reopened.retry(); XCTAssertNil(reopened.pending); XCTAssertFalse(reopened.pendingFileExists)
        XCTAssertEqual(fixture.mutationCount, 1); let calls = fixture.recorded("handoff_team_admin")
        XCTAssertEqual(calls.count, 2); XCTAssertEqual(calls[0], calls[1]); XCTAssertFalse(restored.canAdmin)
    }

    func testMalformedRosterAndInvitationResponsesPreserveAuthorizedCache() async throws {
        let (team, fixture, _, _, _) = try await setup(); let model = TeamAdministration(team: team); await model.refresh()
        let members = model.members, invitations = model.invitations; XCTAssertFalse(members.isEmpty); XCTAssertFalse(invitations.isEmpty)
        fixture.overrideRoster(.object(["team_id": .id(AdministrationFixture.teamA), "members": .string("not a roster")]))
        await model.refresh(); XCTAssertNotNil(model.error); XCTAssertEqual(model.members, members); XCTAssertEqual(model.invitations, invitations)
        fixture.overrideRoster(nil); fixture.changeServerName("New server data must remain uncommitted")
        fixture.overrideInvitations(.object(["team_id": .id(AdministrationFixture.teamB), "invitations": .array([AdministrationFixture.invitation(team: AdministrationFixture.teamB)]), "has_more": .bool(false), "next_invitation_id": .null]))
        await model.refresh(); XCTAssertNotNil(model.error); XCTAssertEqual(model.members, members); XCTAssertEqual(model.invitations, invitations)
    }
    func testRenderedAdministrationPanelOnlyReadsIsolatedTeamAndPreservesReader() async throws {
        let (team, fixture, _, _, _) = try await setup()
        let reader = team.reader
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene), host = UIHostingController(rootView: TeamAdministrationView(team: team))
        window.frame = scene.coordinateSpace.bounds; window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        let deadline = ContinuousClock().now.advanced(by: .seconds(8))
        while fixture.recorded("get_team_invitations").isEmpty, ContinuousClock().now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(200)); host.view.layoutIfNeeded()
        XCTAssertFalse(fixture.recorded("get_team_roster").isEmpty); XCTAssertFalse(fixture.recorded("get_team_invitations").isEmpty)
        XCTAssertEqual(fixture.mutationCount, 0); XCTAssertTrue(team.reader === reader)
        var rendered = false
        let image = UIGraphicsImageRenderer(size: host.view.bounds.size).image { _ in rendered = host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
        XCTAssertTrue(rendered); XCTAssertGreaterThan(image.size.width, 100); XCTAssertGreaterThan(image.size.height, 100)
        let attachment = XCTAttachment(image: image); attachment.name = "Build7 team administration rendered on iPad"; attachment.lifetime = .keepAlways; add(attachment)
    }

}
