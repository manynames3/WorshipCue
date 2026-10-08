import XCTest
import Foundation
import PDFKit
import PencilKit
import WorshipCueCore
import WorshipCueLocal
import WorshipCueRemote
@testable import WorshipCue

/// Exercises the real native adapter/vault with a controlled HTTP transport.
/// These are not hosted Supabase, physical Pencil, or multi-iPad tests.
private final class TeamTestProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var fixture: TeamFixture?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let data = Self.fixture?.blob(request) {
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/octet-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self); return
        }
        Self.fixture?.respond(request) { [weak self] status, value in
            guard let self else { return }
            if status == 0 { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try! JSONEncoder().encode(value))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

private final class TeamFixture: @unchecked Sendable {
    static let userA = UUID(uuidString: "40000000-0000-0000-0000-000000000001")!
    static let userB = UUID(uuidString: "40000000-0000-0000-0000-000000000002")!
    static let church = UUID(uuidString: "41000000-0000-0000-0000-000000000001")!
    static let team = UUID(uuidString: "42000000-0000-0000-0000-000000000001")!
    static let songA = UUID(uuidString: "43000000-0000-0000-0000-000000000001")!
    static let songB = UUID(uuidString: "43000000-0000-0000-0000-000000000002")!
    static let a1 = UUID(uuidString: "44000000-0000-0000-0000-000000000001")!
    static let a2 = UUID(uuidString: "44000000-0000-0000-0000-000000000002")!
    static let b1 = UUID(uuidString: "44000000-0000-0000-0000-000000000003")!
    static let setlist = UUID(uuidString: "45000000-0000-0000-0000-000000000001")!
    static let itemA = UUID(uuidString: "46000000-0000-0000-0000-000000000001")!
    static let itemB = UUID(uuidString: "46000000-0000-0000-0000-000000000002")!
    static let live = UUID(uuidString: "47000000-0000-0000-0000-000000000001")!
    private let lock = NSLock()
    var charts: [TeamJSON] = [], assets: [TeamJSON] = [], originals: [UUID: Data] = [:]
    private var user = userA, offline = false, ended = false, revision: Int64 = 1
    private var preferences: [UUID: UUID] = [userA: a1, userB: a2]
    private var latest: TeamJSON = .null, calls: [TeamJSON] = [], requests: [(String, TeamJSON)] = []
    private var failPublication = false, conflictInk = false, failHeadReads = false, pausedPath: String?
    private var waiting: [((Int, TeamJSON) -> Void)] = []
    private var heads: [String: TeamJSON] = [:], blobs: [String: Data] = [:]
    private func identityKey(_ i: TeamJSON) -> String {
        [i["scope"].text ?? "", i["owner_user_id"].text ?? "", i["performance_item_id"].text ?? "", i["chart_version_id"].text ?? "", String(i["page_index"].integer ?? 0)].joined(separator: "/")
    }
    func installHead(_ head: TeamJSON, archive: Data) {
        lock.withLock {
            heads[identityKey(head)] = head; blobs[head["native_storage_key"].text!] = archive
            assets.append(.object(["id": head["native_asset_id"], "church_id": .id(Self.church), "storage_key": head["native_storage_key"], "sha256": head["native_sha256"], "bytes": head["native_bytes"]]))
        }
    }
    func blob(_ request: URLRequest) -> Data? {
        lock.withLock {
            guard !offline, let path = request.url?.path, let marker = path.range(of: "/worshipcue-private/") else { return nil }
            return blobs[String(path[marker.upperBound...])]
        }
    }

    func setUser(_ value: UUID) { lock.withLock { user = value } }
    func setOffline(_ value: Bool) { lock.withLock { offline = value } }
    func failCalls(_ value: Bool) { lock.withLock { failPublication = value } }
    func rejectInk(_ value: Bool) { lock.withLock { conflictInk = value } }
    func failHeads(_ value: Bool) { lock.withLock { failHeadReads = value } }
    func pause(_ path: String) { lock.withLock { pausedPath = path } }
    var paused: Bool { lock.withLock { !waiting.isEmpty } }
    func release(_ status: Int = 200, _ value: TeamJSON = .null) {
        let callbacks = lock.withLock { let result = waiting; waiting = []; pausedPath = nil; return result }
        for callback in callbacks { callback(status, value) }
    }
    func recorded(_ name: String) -> [TeamJSON] { lock.withLock { requests.filter { $0.0 == name }.map(\.1) } }
    func call(_ sequence: Int64, song: UUID = songA, chart: UUID = a2, item: UUID = itemA) -> TeamJSON {
        .object(["id": .id(UUID()), "session_id": .id(Self.live), "sequence": .int(sequence), "song_id": .id(song),
            "team_chart_version_id": .id(chart), "performance_item_id": .id(item), "performance_key": .string("G")])
    }
    func deliver(_ call: TeamJSON) { lock.withLock { latest = call; calls.insert(call, at: 0); revision += 1 } }
    func snapshotValue(ended: Bool? = nil, revision: Int64? = nil) -> TeamJSON {
        lock.withLock { snapshot(ended: ended ?? self.ended, revision: revision ?? self.revision) }
    }
    private func snapshot(ended: Bool, revision: Int64) -> TeamJSON {
        .object(["id": .id(Self.live), "church_id": .id(Self.church), "setlist_id": .id(Self.setlist),
            "status": .string(ended ? "ENDED" : "LIVE"), "state_revision": .int(revision),
            "latest_sequence": latest["sequence"] == .null ? .int(0) : latest["sequence"], "latest_call": latest, "history": .array(calls)])
    }
    static func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(contentsOf: buffer.prefix(n)) }
        return data
    }
    func respond(_ request: URLRequest, completion: @escaping (Int, TeamJSON) -> Void) {
        let name = request.url!.lastPathComponent
        let body = (try? JSONDecoder().decode(TeamJSON.self, from: Self.body(request))) ?? .null
        let p = body["p"]
        lock.lock()
        requests.append((name, p))
        if offline { lock.unlock(); completion(0, .null); return }
        if name == pausedPath { waiting.append(completion); lock.unlock(); return }
        var result: TeamJSON = .null, status = 200
        switch name {
        case "verify", "token":
            result = .object(["user": .object(["id": .id(user), "is_anonymous": .bool(false)]),
                "access_token": .string("synthetic-access"), "refresh_token": .string("synthetic-refresh"), "expires_in": .int(3600)])
        case "memberships": result = .array([.object(["user_id": .id(user), "church_id": .id(Self.church), "team_id": .id(Self.team), "role": .string("admin"), "active": .bool(true)])])
        case "songs": result = .array([Self.songA, Self.songB].map { .object(["id": .id($0), "church_id": .id(Self.church), "canonical_title": .string($0 == Self.songA ? "Synthetic A" : "Synthetic B")]) })
        case "chart_versions": result = .array(charts)
        case "assets": result = .array(assets)
        case "setlists": result = .array([.object(["id": .id(Self.setlist), "church_id": .id(Self.church), "team_id": .id(Self.team), "title": .string("Synthetic rehearsal"), "revision": .int(1)])])
        case "performance_items": result = .array([Self.itemA, Self.itemB].enumerated().map { index, id in .object(["id": .id(id), "church_id": .id(Self.church), "setlist_id": .id(Self.setlist), "song_id": .id(index == 0 ? Self.songA : Self.songB), "team_chart_version_id": .id(index == 0 ? Self.a2 : Self.b1), "performance_key": .string("G"), "kind": .string("planned"), "active": .bool(true), "position": .int(Int64(index))]) })
        case "personal_preferences": result = .array([.object(["user_id": .id(user), "church_id": .id(Self.church), "song_id": .id(Self.songA), "preferred_version_id": .id(preferences[user] ?? Self.a1)])])
        case "set_personal_preference": preferences[user] = p["preferred_version_id"].uuid!; result = .object(["revision": .int(1)])
        case "get_session_snapshot": result = snapshot(ended: ended, revision: revision)
        case "get_annotation_head":
            if failHeadReads { status = 503 }
            else { result = heads[identityKey(p["layer_identity"])] ?? .null }
        case "live_sessions": result = .array([snapshot(ended: ended, revision: revision)])
        case "editor_leases": result = .array([])
        case "acquire_editor": result = .object(["setlist_id": .id(Self.setlist), "epoch": .int(2), "active": .bool(true), "device_id": p["device_id"], "controller_user_id": .id(user), "expires_at": .string(ISO8601DateFormatter().string(from: Date().addingTimeInterval(60)))])
        case "end_session": ended = true; revision += 1; result = snapshot(ended: ended, revision: revision)
        case "publish_call":
            if failPublication { status = 503 }
            else { result = .object(["command_id": p["command_id"]]) }
        case "stage_asset":
            let id = UUID()
            result = .object(["id": .id(id), "church_id": .id(Self.church), "storage_key": .string("synthetic/\(id)"), "sha256": p["sha256"], "bytes": p["expected_bytes"]])
            assets.append(result)
        case "finalize-asset": result = assets.first { $0["id"] == body["asset_id"] } ?? .null
        case "save_annotation_revision":
            if conflictInk { status = 400; result = .object(["message": .string("REVISION_CONFLICT")]) }
            else { result = .object(["revision_number": .int((p["parent_revision"].integer ?? 0) + 1)]) }
        case "preflight_manifest": result = .object(["setlist_id": .id(Self.setlist), "setlist_revision": .int(1), "charts": .array(charts), "annotation_heads": .array(heads.values.filter { $0["scope"].text == "team" }.sorted { $0["native_storage_key"].text! < $1["native_storage_key"].text! })])
        default: break
        }
        lock.unlock(); completion(status, result)
    }
}

@MainActor final class TeamWorkspaceTests: XCTestCase {
    private func expectTrue(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) { XCTAssertTrue(value, file: file, line: line) }
    private func expectFalse(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) { XCTAssertFalse(value, file: file, line: line) }
    private func setupWorkspace() async throws -> (TeamWorkspace, TeamFixture, URL, RemoteConfiguration, URLSession) {
        let fixture = TeamFixture()
        for (index, tuple) in [(TeamFixture.a1, TeamFixture.songA, "song_A_v1_G"), (TeamFixture.a2, TeamFixture.songA, "song_A_v2_G"), (TeamFixture.b1, TeamFixture.songB, "song_A_v3_A")].enumerated() {
            let source = try XCTUnwrap(Bundle.main.url(forResource: tuple.2, withExtension: "pdf", subdirectory: "pdfs"))
            let data = try Data(contentsOf: source), document = try XCTUnwrap(PDFDocument(data: data)), asset = UUID()
            let pages = try (0..<document.pageCount).map { try TeamWorkspace.jsonGeometry(document.page(at: $0)!.canonicalGeometry()) }
            fixture.originals[tuple.0] = data
            fixture.charts.append(.object(["id": .id(tuple.0), "church_id": .id(TeamFixture.church), "song_id": .id(tuple.1), "version_number": .int(index == 1 ? 2 : 1), "label": .string(tuple.2), "written_key": .string("G"), "pdf_asset_id": .id(asset), "page_count": .int(Int64(document.pageCount)), "page_manifest": .array(pages)]))
            fixture.assets.append(.object(["id": .id(asset), "church_id": .id(TeamFixture.church), "storage_key": .string("synthetic/\(asset).pdf"), "sha256": .string(TeamWorkspace.hash(data)), "bytes": .int(Int64(data.count))]))
        }
        TeamTestProtocol.fixture = fixture
        let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [TeamTestProtocol.self]
        let transport = URLSession(configuration: c), root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let config = try RemoteConfiguration(url: URL(string: "https://unit-\(UUID().uuidString.lowercased()).invalid")!, publishableKey: "sb_publishable_synthetic")
        let team = TeamWorkspace(testRoot: root, configuration: config, transport: transport, realtimeEnabled: false)
        addTeardownBlock { @MainActor in fixture.release(); team.suspend(); _ = await team.logout(); transport.invalidateAndCancel(); TeamTestProtocol.fixture = nil; try? FileManager.default.removeItem(at: root) }
        expectTrue(await team.signIn("synthetic@example.test", code: "123456"))
        XCTAssertNil(team.reader); XCTAssertTrue(try XCTUnwrap(team.cache).charts.isEmpty, "Remote cache must not seed local sample charts")
        try seed(team, fixture)
        return (team, fixture, root, config, transport)
    }
    private func seed(_ team: TeamWorkspace, _ fixture: TeamFixture) throws {
        let cache = try XCTUnwrap(team.cache)
        for json in fixture.charts {
            let id = try json.requiredID("id"), song = try json.requiredID("song_id"), data = fixture.originals[id]!
            let v = LibraryVersion(id: id, songID: song, number: Int(json["version_number"].integer!), assetID: id, label: try json.requiredText("label"), writtenKey: "G")
            try cache.cachePublished(data, song: LibrarySong(id: song, title: song == TeamFixture.songA ? "Synthetic A" : "Synthetic B"), version: v,
                sha256: TeamWorkspace.hash(data), bytes: data.count, pages: json["page_manifest"].list.map(TeamWorkspace.geometry))
        }
    }
    private func waitPaused(_ fixture: TeamFixture) async throws {
        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        while !fixture.paused, ContinuousClock().now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(fixture.paused); if !fixture.paused { throw RemoteError.unavailable }
    }
    private func head(chart: UUID, page: Int, geometry: PageGeometry, archive: Data, item: UUID? = nil) throws -> TeamJSON {
        let id = UUID()
        return .object(["church_id": .id(TeamFixture.church), "chart_version_id": .id(chart), "page_index": .int(Int64(page)),
            "scope": .string(item == nil ? "personal" : "team"), "owner_user_id": item == nil ? .id(TeamFixture.userA) : .null,
            "performance_item_id": item.map(TeamJSON.id) ?? .null, "revision_number": .int(1), "native_asset_id": .id(id),
            "native_storage_key": .string("synthetic/\(id).drawing"), "native_sha256": .string(TeamWorkspace.hash(archive)),
            "native_bytes": .int(Int64(archive.count)), "geometry": try TeamWorkspace.jsonGeometry(geometry)])
    }
    private func readyOverlay(_ stand: MusicStand) async throws -> PageInkView {
        let page = try XCTUnwrap(stand.pdfView.document?.page(at: stand.pageIndex))
        let overlay = try XCTUnwrap(stand.pdfView(stand.pdfView, overlayViewFor: page) as? PageInkView)
        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        while !overlay.ready, ContinuousClock().now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(overlay.ready)
        return overlay
    }
    func testSameChartManualReopenKeepsAcknowledgedOccurrenceAndSharedLayer() async throws {
        let (team, fixture, _, _, _) = try await setupWorkspace()
        let cache = try XCTUnwrap(team.cache), geometry = try XCTUnwrap(cache.library.assets.first { $0.id == TeamFixture.a2 }?.pages?.first)
        let ink = MusicStand.sampleTeamDrawing().dataRepresentation()
        fixture.installHead(try head(chart: TeamFixture.a2, page: 0, geometry: geometry, archive: ink, item: TeamFixture.itemA), archive: ink)
        let call = fixture.call(1); fixture.deliver(call); expectTrue(await team.joinSession(TeamFixture.live)); expectTrue(await team.accept(try call.call()))
        expectTrue(await team.openVersion(TeamFixture.a1, page: 1))
        XCTAssertTrue(team.teamMismatch); XCTAssertEqual(team.reader?.performanceItemID, TeamFixture.itemA)
        XCTAssertEqual(team.displayedCall?.id, call["id"].uuid); XCTAssertEqual(team.currentPerformanceKey, "G")
        expectTrue(await team.openVersion(TeamFixture.a2)); expectTrue(await team.openVersion(TeamFixture.a2))
        XCTAssertFalse(team.teamMismatch); XCTAssertEqual(team.reader?.performanceItemID, TeamFixture.itemA)
        let overlay = try await readyOverlay(XCTUnwrap(team.reader))
        XCTAssertNotNil(overlay.team.image); XCTAssertFalse(overlay.team.isHidden)
        XCTAssertEqual(fixture.recorded("acknowledge_open").count, 1, "A manual version reopen must not acknowledge another cue")
    }
    func testUncachedInkDoesNotHidePreparedOfflinePaperOrTrapSavedDraft() async throws {
        let (team, fixture, _, _, _) = try await setupWorkspace()
        expectTrue(await team.openVersion(TeamFixture.b1)); expectTrue(await team.prepare(try XCTUnwrap(team.setlists.first)))
        let call = try fixture.call(1).call(), editor = TeamInkDraft(team: team, call: call, editable: true)
        await editor.load(); XCTAssertTrue(editor.ready); editor.changed(MusicStand.sampleTeamDrawing())
        team.suspend(); fixture.setOffline(true)
        let preview = TeamInkDraft(team: team, call: call, editable: false, initialPage: 1)
        await preview.load()
        XCTAssertEqual(preview.document?.pageCount, 3); XCTAssertNotNil(preview.geometry)
        XCTAssertFalse(preview.ready); XCTAssertNotNil(preview.error); XCTAssertTrue(preview.canTurnPages)
        await preview.move(-1); XCTAssertEqual(preview.page, 0); XCTAssertTrue(preview.ready)
        await preview.move(1); XCTAssertEqual(preview.page, 1); XCTAssertNotNil(preview.document)
        await preview.move(1); XCTAssertEqual(preview.page, 2); XCTAssertNotNil(preview.document)
        await preview.move(1); XCTAssertEqual(preview.page, 2, "Paper navigation must stay within the verified manifest")
        await editor.move(1)
        XCTAssertEqual(editor.page, 1); XCTAssertFalse(editor.ready); XCTAssertFalse(editor.dirty)
        XCTAssertNotEqual(try team.teamDraft(call.performanceItemID, chart: call.teamChartVersionID, page: 0), .null)
        XCTAssertEqual(team.reader?.current?.id, TeamFixture.b1, "Read-only team preview must preserve the musician's reader")
    }
    func testDelayedPersonalHeadCannotAdvanceTheStoreBeneathAnActiveLocalStroke() async throws {
        let (team, fixture, _, _, _) = try await setupWorkspace()
        expectTrue(await team.openVersion(TeamFixture.a1))
        let stand = try XCTUnwrap(team.reader), overlay = try await readyOverlay(stand), store = try XCTUnwrap(stand.personalStore)
        let remote = MusicStand.sampleTeamDrawing(), local = remote.transformed(using: CGAffineTransform(translationX: 0, y: 100))
        let remoteBytes = remote.dataRepresentation(), localBytes = local.dataRepresentation()
        let remoteHead = try head(chart: TeamFixture.a1, page: 0, geometry: overlay.geometry, archive: remoteBytes)
        fixture.installHead(remoteHead, archive: remoteBytes)
        fixture.pause("get_annotation_head")
        let downloading = Task { await team.prepare(try XCTUnwrap(team.setlists.first)) }; try await waitPaused(fixture)
        stand.canvasViewDidBeginUsingTool(overlay.personal)
        overlay.personal.drawing = local; stand.canvasViewDrawingDidChange(overlay.personal)
        fixture.release(200, remoteHead)
        expectTrue(try await downloading.value)
        let beforePenUp = try await store.load(overlay.address); XCTAssertNil(beforePenUp)
        XCTAssertEqual(overlay.personal.drawing.bounds, local.bounds)
        stand.canvasViewDidEndUsingTool(overlay.personal); try await stand.flush()
        let saved = try await store.load(overlay.address); XCTAssertEqual(saved?.archive, localBytes)
        expectTrue(try await store.hasPending(overlay.address)); XCTAssertNil(stand.error)
    }
    func testAcceptedPublicationRemainsSuccessfulWhenDisplayRefreshFails() async throws {
        let (team, fixture, _, _, _) = try await setupWorkspace()
        let call = fixture.call(1); fixture.deliver(call); expectTrue(await team.joinSession(TeamFixture.live))
        expectTrue(await team.accept(try call.call(), explicitVersion: TeamFixture.a2)); expectTrue(await team.acquire(TeamFixture.setlist, takeover: false))
        let draft = TeamInkDraft(team: team, call: try call.call(), editable: true)
        await draft.load(); draft.changed(MusicStand.sampleTeamDrawing()); fixture.failHeads(true)
        expectTrue(await draft.publish())
        XCTAssertFalse(draft.dirty); XCTAssertTrue(team.message.contains("게시됨"))
        XCTAssertEqual(try team.teamDraft(TeamFixture.itemA, chart: TeamFixture.a2, page: 0), .null)
        expectFalse(await draft.publish()); XCTAssertEqual(fixture.recorded("save_annotation_revision").count, 1)
    }
    func testIncomingCuePreservesChartPagePrivateInkPreferenceAndDisplayedPreviewContext() async throws {
        let (team, fixture, _, _, _) = try await setupWorkspace()
        expectTrue(await team.openVersion(TeamFixture.a1))
        let stand = try XCTUnwrap(team.reader); await stand.turnPage(1); team.navigationChanged()
        let store = try XCTUnwrap(stand.personalStore), geometry = try stand.pdfView.document!.page(at: 1)!.canonicalGeometry()
        let address = try InkAddress(churchID: stand.church, ownerID: stand.owner, versionID: TeamFixture.a1, pageIndex: 1)
        let ink = MusicStand.sampleTeamDrawing().dataRepresentation()
        try await store.save(InkSnapshot(address: address, geometry: geometry, generation: 1, archive: ink))
        let a = fixture.call(1); fixture.deliver(a)
        expectTrue(await team.joinSession(TeamFixture.live))
        XCTAssertEqual(team.reader?.current?.id, TeamFixture.a1); XCTAssertEqual(stand.pageIndex, 1)
        XCTAssertEqual(team.pending?.id, a["id"].uuid); XCTAssertTrue(fixture.recorded("acknowledge_open").isEmpty)
        expectTrue(await team.accept(try a.call()))
        XCTAssertEqual(stand.pageIndex, 1); XCTAssertTrue(team.teamMismatch)
        XCTAssertEqual(team.preferredVersions[TeamFixture.songA], TeamFixture.a1)
        XCTAssertEqual(fixture.recorded("acknowledge_open").last?["selected_chart_version_id"].uuid, TeamFixture.a1)
        let b = fixture.call(2, song: TeamFixture.songB, chart: TeamFixture.b1, item: TeamFixture.itemB); fixture.deliver(b); try await team.reconcile()
        XCTAssertEqual(team.reader?.current?.id, TeamFixture.a1); XCTAssertEqual(stand.pageIndex, 1)
        XCTAssertEqual(team.displayedCall?.id, a["id"].uuid); XCTAssertTrue(team.teamMismatch); XCTAssertEqual(team.pending?.id, b["id"].uuid)
        let stored = try await store.load(address); XCTAssertEqual(stored?.archive, ink)
        XCTAssertEqual(try stand.sourceBytes(TeamFixture.a1), fixture.originals[TeamFixture.a1])
    }
    func testOfflineRelaunchRestoresReaderPageAndDurablePreferredVersionWithoutCueReplay() async throws {
        let (team, fixture, root, config, transport) = try await setupWorkspace()
        expectTrue(await team.openVersion(TeamFixture.a1)); await team.reader?.turnPage(1); team.navigationChanged()
        let a = fixture.call(1); fixture.deliver(a); expectTrue(await team.joinSession(TeamFixture.live)); expectTrue(await team.accept(try a.call()))
        team.suspend(); fixture.setOffline(true); await team.prefer(TeamFixture.a2)
        XCTAssertEqual(team.reader?.current?.id, TeamFixture.a1)
        let restored = TeamWorkspace(testRoot: root, configuration: config, transport: transport, realtimeEnabled: false)
        await restored.restore()
        XCTAssertFalse(restored.online); XCTAssertEqual(restored.reader?.current?.id, TeamFixture.a1); XCTAssertEqual(restored.reader?.pageIndex, 1)
        XCTAssertEqual(restored.displayedCall?.id, a["id"].uuid); XCTAssertNil(restored.pending); XCTAssertEqual(restored.preferredVersions[TeamFixture.songA], TeamFixture.a2)
        XCTAssertTrue(fixture.recorded("set_personal_preference").isEmpty); XCTAssertTrue(fixture.recorded("publish_call").isEmpty)
        fixture.setOffline(false); await restored.refresh()
        XCTAssertEqual(fixture.recorded("set_personal_preference").last?["preferred_version_id"].uuid, TeamFixture.a2)
        XCTAssertEqual(restored.reader?.current?.id, TeamFixture.a1); XCTAssertEqual(restored.reader?.pageIndex, 1)
        restored.suspend(); _ = await restored.logout()
    }
    func testUserNavigationDuringCueLoadCancelsOpenAndAcknowledgement() async throws {
        let (team, fixture, _, _, _) = try await setupWorkspace()
        expectTrue(await team.openVersion(TeamFixture.b1))
        let call = fixture.call(1); fixture.deliver(call); expectTrue(await team.joinSession(TeamFixture.live))
        fixture.pause("get_annotation_head")
        let opening = Task { await team.accept(try call.call()) }
        try await waitPaused(fixture); team.navigationChanged(); fixture.release()
        expectFalse(try await opening.value)
        XCTAssertEqual(team.reader?.current?.id, TeamFixture.b1); XCTAssertEqual(team.pending?.id, call["id"].uuid)
        XCTAssertTrue(fixture.recorded("acknowledge_open").isEmpty)
    }
    func testSessionEndIsTerminalAndPersistsAcrossOfflineLaunch() async throws {
        let (team, fixture, root, config, transport) = try await setupWorkspace()
        let call = fixture.call(1); fixture.deliver(call); expectTrue(await team.joinSession(TeamFixture.live))
        expectTrue(await team.acquire(TeamFixture.setlist, takeover: false)); expectTrue(await team.endSession())
        XCTAssertTrue(try XCTUnwrap(team.live).ended); XCTAssertNil(team.pending)
        fixture.pause("get_session_snapshot")
        let stale = Task { try await team.reconcile() }; try await waitPaused(fixture)
        fixture.release(200, fixture.snapshotValue(ended: false, revision: 1)); try await stale.value
        XCTAssertTrue(try XCTUnwrap(team.live).ended); XCTAssertEqual(team.snapshot["status"].text, "ENDED")
        team.suspend(); fixture.setOffline(true)
        let restored = TeamWorkspace(testRoot: root, configuration: config, transport: transport, realtimeEnabled: false); await restored.restore()
        XCTAssertTrue(try XCTUnwrap(restored.live).ended); XCTAssertNil(restored.pending)
        restored.suspend(); _ = await restored.logout()
    }
    func testDifferentSongWithSameKeyDoesNotReuseUncertainAdHocCommand() async throws {
        let (team, fixture, _, _, _) = try await setupWorkspace()
        let call = fixture.call(1); fixture.deliver(call); expectTrue(await team.joinSession(TeamFixture.live)); expectTrue(await team.acquire(TeamFixture.setlist, takeover: false))
        fixture.failCalls(true)
        expectFalse(await team.announcePrepared(itemID: nil, versionID: TeamFixture.a2, key: "G"))
        await team.refresh(); fixture.failCalls(false)
        expectTrue(await team.announcePrepared(itemID: nil, versionID: TeamFixture.b1, key: "G"))
        let requests = fixture.recorded("publish_call"); XCTAssertEqual(requests.count, 2)
        XCTAssertNotEqual(requests[0]["command_id"], requests[1]["command_id"])
        XCTAssertNotEqual(requests[0]["performance_item_id"], requests[1]["performance_item_id"])
        XCTAssertEqual(requests[1]["song_id"].uuid, TeamFixture.songB)
        XCTAssertEqual(fixture.recorded("publish_call").count, 2, "Refresh must never replay publication")
    }
    func testPublishingDraftFreezesEditsAndPreservesExactUncertainPayload() async throws {
        let (team, fixture, _, _, _) = try await setupWorkspace()
        expectTrue(await team.acquire(TeamFixture.setlist, takeover: false))
        let call = try fixture.call(1).call(), draft = TeamInkDraft(team: team, call: call, editable: true)
        await draft.load(); XCTAssertTrue(draft.ready)
        let drawing = MusicStand.sampleTeamDrawing(); draft.changed(drawing)
        fixture.pause("save_annotation_revision")
        let sending = Task { await draft.publish() }; try await waitPaused(fixture)
        XCTAssertTrue(draft.publishing)
        let frozen = try team.teamDraft(call.performanceItemID, chart: call.teamChartVersionID, page: 0)
        XCTAssertNotEqual(frozen["payload"], .null)
        draft.changed(drawing.transformed(using: CGAffineTransform(translationX: 100, y: 100))); draft.persist(); await draft.rebaseExplicitly()
        XCTAssertEqual(try team.teamDraft(call.performanceItemID, chart: call.teamChartVersionID, page: 0), frozen)
        fixture.release(400, .object(["message": .string("REVISION_CONFLICT")]))
        expectFalse(await sending.value)
        fixture.rejectInk(true); expectFalse(await draft.publish())
        let requests = fixture.recorded("save_annotation_revision"); XCTAssertEqual(requests.count, 2); XCTAssertEqual(requests[0], requests[1])
        XCTAssertEqual(try team.teamDraft(call.performanceItemID, chart: call.teamChartVersionID, page: 0), frozen)
    }
    func testPreflightRefreshesMetadataAndKeepsCurrentReaderAndPrivateInk() async throws {
        let (team, fixture, _, _, _) = try await setupWorkspace()
        expectTrue(await team.openVersion(TeamFixture.a1)); await team.reader?.turnPage(1); team.navigationChanged()
        let stand = try XCTUnwrap(team.reader), original = try stand.sourceBytes(TeamFixture.a1)
        let priorReads = fixture.recorded("chart_versions").count
        expectTrue(await team.prepare(try XCTUnwrap(team.setlists.first)))
        XCTAssertGreaterThan(fixture.recorded("chart_versions").count, priorReads)
        XCTAssertGreaterThan(fixture.recorded("get_annotation_head").count, 3, "Personal heads must be reconciled for prepared versions")
        XCTAssertEqual(team.reader?.current?.id, TeamFixture.a1); XCTAssertEqual(team.reader?.pageIndex, 1)
        XCTAssertEqual(try stand.sourceBytes(TeamFixture.a1), original)
    }
    func testAccountsKeepChartPageAndPersonalInkInIndependentNamespaces() async throws {
        let (a, fixture, root, config, transport) = try await setupWorkspace()
        expectTrue(await a.openVersion(TeamFixture.a1)); await a.reader?.turnPage(1); a.navigationChanged()
        let aStand = try XCTUnwrap(a.reader), aStore = try XCTUnwrap(aStand.personalStore)
        let address = try InkAddress(churchID: aStand.church, ownerID: aStand.owner, versionID: TeamFixture.a1, pageIndex: 1)
        let ink = MusicStand.sampleTeamDrawing().dataRepresentation(), geometry = try aStand.pdfView.document!.page(at: 1)!.canonicalGeometry()
        try await aStore.save(InkSnapshot(address: address, geometry: geometry, generation: 1, archive: ink))
        expectTrue(await a.logout()); fixture.setUser(TeamFixture.userB)
        let b = TeamWorkspace(testRoot: root, configuration: config, transport: transport, realtimeEnabled: false)
        expectTrue(await b.signIn("synthetic@example.test", code: "123456")); try seed(b, fixture); expectTrue(await b.openVersion(TeamFixture.a2))
        XCTAssertEqual(b.cache?.owner, TeamFixture.userB); XCTAssertEqual(b.preferredVersions[TeamFixture.songA], TeamFixture.a2)
        let bStore = try XCTUnwrap(b.cache?.personalStore), otherInk = try await bStore.load(address)
        XCTAssertNil(otherInk); expectTrue(await b.logout()); fixture.setUser(TeamFixture.userA)
        let returning = TeamWorkspace(testRoot: root, configuration: config, transport: transport, realtimeEnabled: false)
        expectTrue(await returning.signIn("synthetic@example.test", code: "123456")); expectTrue(await returning.openVersion(TeamFixture.a1))
        XCTAssertEqual(returning.reader?.pageIndex, 1); XCTAssertEqual(returning.preferredVersions[TeamFixture.songA], TeamFixture.a1)
        let saved = try await XCTUnwrap(returning.cache?.personalStore).load(address); XCTAssertEqual(saved?.archive, ink)
        returning.suspend(); _ = await returning.logout()
    }
    func testPersonalWorkerRebasesNewerInkAfterFrozenPredecessorAcknowledgement() async throws {
        let (team, fixture, _, _, _) = try await setupWorkspace()
        let cache = try XCTUnwrap(team.cache), store = try XCTUnwrap(cache.personalStore)
        let address = try InkAddress(churchID: cache.church, ownerID: cache.owner, versionID: TeamFixture.a1, pageIndex: 0)
        let geometry = try XCTUnwrap(cache.library.assets.first { $0.id == TeamFixture.a1 }?.pages?.first)
        let first = MusicStand.sampleTeamDrawing(), newer = first.transformed(using: CGAffineTransform(translationX: 0, y: 100))
        try await store.save(InkSnapshot(address: address, geometry: geometry, generation: 1, archive: first.dataRepresentation()))
        fixture.pause("save_annotation_revision")
        let sending = Task { await team.syncPersonal() }; try await waitPaused(fixture)
        try await store.save(InkSnapshot(address: address, geometry: geometry, generation: 2, archive: newer.dataRepresentation()))
        fixture.release(200, .object(["revision_number": .int(1)])); await sending.value
        let requests = fixture.recorded("save_annotation_revision")
        XCTAssertEqual(requests.map { $0["parent_revision"].integer }, [0, 1])
        let jobs = try await store.pendingUploads(); XCTAssertTrue(jobs.isEmpty)
        let saved = try await store.load(address); XCTAssertEqual(saved?.archive, newer.dataRepresentation())
        XCTAssertNil(team.error)
    }
    func testPreparedPersonalAndExactTeamArchivesRestoreOfflineWithoutMergingLayers() async throws {
        let (team, fixture, _, _, _) = try await setupWorkspace()
        let cache = try XCTUnwrap(team.cache), personal = MusicStand.sampleTeamDrawing().transformed(using: CGAffineTransform(translationX: 0, y: 100))
        let shared = MusicStand.sampleTeamDrawing(), personalBytes = personal.dataRepresentation(), teamBytes = shared.dataRepresentation()
        let personalGeometry = try XCTUnwrap(cache.library.assets.first { $0.id == TeamFixture.a1 }?.pages?.first)
        let teamGeometry = try XCTUnwrap(cache.library.assets.first { $0.id == TeamFixture.a2 }?.pages?.first)
        fixture.installHead(try head(chart: TeamFixture.a1, page: 0, geometry: personalGeometry, archive: personalBytes), archive: personalBytes)
        fixture.installHead(try head(chart: TeamFixture.a2, page: 0, geometry: teamGeometry, archive: teamBytes, item: TeamFixture.itemA), archive: teamBytes)
        expectTrue(await team.openVersion(TeamFixture.b1))
        expectTrue(await team.prepare(try XCTUnwrap(team.setlists.first)))
        XCTAssertEqual(team.reader?.current?.id, TeamFixture.b1)
        let address = try InkAddress(churchID: cache.church, ownerID: cache.owner, versionID: TeamFixture.a1, pageIndex: 0)
        let saved = try await XCTUnwrap(cache.personalStore).load(address); XCTAssertEqual(saved?.archive, personalBytes)
        let call = fixture.call(1); fixture.deliver(call); expectTrue(await team.joinSession(TeamFixture.live)); expectTrue(await team.accept(try call.call()))
        XCTAssertEqual(team.reader?.current?.id, TeamFixture.a1); XCTAssertTrue(team.teamMismatch)
        team.suspend(); fixture.setOffline(true)
        expectTrue(await team.openVersion(TeamFixture.a2))
        XCTAssertFalse(team.teamMismatch); XCTAssertEqual(team.preferredVersions[TeamFixture.songA], TeamFixture.a1)
        let page = try XCTUnwrap(cache.pdfView.document?.page(at: 0))
        let overlay = try XCTUnwrap(cache.pdfView(cache.pdfView, overlayViewFor: page) as? PageInkView)
        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        while !overlay.ready, ContinuousClock().now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let restored = try await team.loadTeamDrawing(item: TeamFixture.itemA, chart: TeamFixture.a2, page: 0)
        XCTAssertTrue(overlay.ready); XCTAssertEqual(restored.0.strokes.count, shared.strokes.count)
        XCTAssertEqual(restored.0.bounds, shared.bounds)
        XCTAssertNotNil(overlay.team.image); XCTAssertFalse(overlay.team.isHidden)
        XCTAssertFalse(overlay.team.isUserInteractionEnabled); XCTAssertTrue(overlay.personal.drawing.strokes.isEmpty)
        let unchanged = try await XCTUnwrap(cache.personalStore).load(address); XCTAssertEqual(unchanged?.archive, personalBytes)
    }
    func testLatePersonalConflictCannotEnterTheNextAccountsStateOrPartition() async throws {
        let (team, fixture, root, _, _) = try await setupWorkspace()
        let cache = try XCTUnwrap(team.cache), store = try XCTUnwrap(cache.personalStore)
        let address = try InkAddress(churchID: cache.church, ownerID: cache.owner, versionID: TeamFixture.a1, pageIndex: 0)
        let geometry = try XCTUnwrap(cache.library.assets.first { $0.id == TeamFixture.a1 }?.pages?.first)
        try await store.save(InkSnapshot(address: address, geometry: geometry, generation: 1, archive: MusicStand.sampleTeamDrawing().dataRepresentation()))
        fixture.rejectInk(true); fixture.pause("get_annotation_head")
        let sending = Task { await team.syncPersonal() }; try await waitPaused(fixture)
        expectTrue(await team.logout()); fixture.setUser(TeamFixture.userB)
        expectTrue(await team.signIn("synthetic@example.test", code: "123456"))
        fixture.release(200, .object(["revision_number": .int(1), "native_asset_id": .id(UUID())])); await sending.value
        XCTAssertEqual(team.session?.userID, TeamFixture.userB); XCTAssertTrue(team.conflicts.isEmpty); XCTAssertNil(team.error)
        let jobs = try await store.pendingUploads(); XCTAssertEqual(jobs.count, 1)
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!.allObjects.compactMap { $0 as? URL }
        XCTAssertFalse(files.contains { $0.path.contains(TeamFixture.userB.uuidString) && $0.lastPathComponent.hasPrefix("conflict-") })
    }
}
