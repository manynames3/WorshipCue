import XCTest
import SwiftUI
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
    var extraMemberships: [TeamJSON] = []
    private var extraSongs: [TeamJSON] = []
    private var extraSetlists: [TeamJSON] = [], extraItems: [TeamJSON] = []
    private var workflowReceipts: [String: TeamJSON] = [:]
    private var lostResponses: Set<String> = []
    private var malformedResponses: Set<String> = []
    private var dropAfterPublication = false
    private var headStatus: Int?
    private var chatMessages: [TeamJSON] = [], chatRevision: Int64 = 0
    private var chatBlocked: Set<UUID> = [], blockRevision: Int64 = 0
    private var chatRead: [String: Int64] = [:], chatMuted: Set<String> = [], chatReports: [TeamJSON] = []
    private var chatReceipts: Set<UUID> = []
    private var memberRole = "admin", unknownUnread = false, failChat = false
    private var preferences: [UUID: UUID] = [userA: a1, userB: a2]
    private var latest: TeamJSON = .null, calls: [TeamJSON] = [], requests: [(String, TeamJSON)] = []
    private var failCreation = false
    private var failPublication = false, conflictInk = false, failHeadReads = false, pausedPath: String?
    private var waiting: [((Int, TeamJSON) -> Void)] = []
    private var pauseNextOnly = false
    private var heads: [String: TeamJSON] = [:], blobs: [String: Data] = [:]
    private func catalogRows(_ name: String) -> TeamJSON {
        switch name {
        case "songs": return .array([Self.songA, Self.songB].map { .object(["id": .id($0), "church_id": .id(Self.church), "team_id": .id(Self.team), "canonical_title": .string($0 == Self.songA ? "Synthetic A" : "Synthetic B")]) } + extraSongs)
        case "chart_versions": return .array(charts)
        case "assets": return .array(assets)
        case "setlists": return .array([.object(["id": .id(Self.setlist), "church_id": .id(Self.church), "team_id": .id(Self.team), "title": .string("Synthetic rehearsal"), "revision": .int(1)])] + extraSetlists)
        case "performance_items": return .array([Self.itemA, Self.itemB].enumerated().map { index, id in .object(["id": .id(id), "church_id": .id(Self.church), "team_id": .id(Self.team), "setlist_id": .id(Self.setlist), "song_id": .id(index == 0 ? Self.songA : Self.songB), "team_chart_version_id": .id(index == 0 ? Self.a2 : Self.b1), "performance_key": .string("G"), "kind": .string("planned"), "active": .bool(true), "position": .int(Int64(index))]) } + extraItems)
        case "personal_preferences": return .array([.object(["user_id": .id(user), "church_id": .id(Self.church), "team_id": .id(Self.team), "song_id": .id(Self.songA), "preferred_version_id": .id(preferences[user] ?? Self.a1)])])
        default: return .array([])
        }
    }
    private func identityKey(_ i: TeamJSON) -> String {
        [i["scope"].text ?? "", i["owner_user_id"].text ?? "", i["performance_item_id"].text ?? "", i["chart_version_id"].text ?? "", String(i["page_index"].integer ?? 0)].joined(separator: "/")
    }
    func installHead(_ head: TeamJSON, archive: Data) {
        lock.withLock {
            heads[identityKey(head)] = head; blobs[head["native_storage_key"].text!] = archive
            assets.append(.object(["id": head["native_asset_id"], "church_id": .id(Self.church), "team_id": .id(Self.team), "storage_key": head["native_storage_key"], "sha256": head["native_sha256"], "bytes": head["native_bytes"]]))
        }
    }
    func blob(_ request: URLRequest) -> Data? {
        lock.withLock {
            guard request.httpMethod == "GET", !offline, let path = request.url?.path, let marker = path.range(of: "/worshipcue-private/") else { return nil }
            return blobs[String(path[marker.upperBound...])]
        }
    }

    func malformedResponseOnce(_ name: String) { lock.withLock { malformedResponses.insert(name) } }
    func loseResponseOnce(_ name: String) { lock.withLock { lostResponses.insert(name) } }
    func dropCatalogAfterPublication(_ value: Bool) { lock.withLock { dropAfterPublication = value } }
    func denyPersonalHeads(_ status: Int?) { lock.withLock { headStatus = status } }
    var createdSongCount: Int { lock.withLock { extraSongs.count } }
    var createdSetlistCount: Int { lock.withLock { extraSetlists.count } }
    var publishedChartCount: Int { lock.withLock { charts.count - 3 } }
    func setMemberRole(_ value: String) { lock.withLock { memberRole = value } }
    func setUnknownUnread(_ value: Bool) { lock.withLock { unknownUnread = value } }
    func failChatActions(_ value: Bool) { lock.withLock { failChat = value } }
    func addChat(_ body: String, author: UUID = userB, room: UUID? = nil, chart: UUID? = nil) -> UUID {
        lock.withLock {
            let id = UUID(); chatRevision += 1
            chatMessages.append(.object(["id": .id(id), "team_id": .id(Self.team), "author_id": .id(author), "body": .string(body),
                "revision": .int(chatRevision), "created_revision": .int(chatRevision), "created_at": .string(ISO8601DateFormatter().string(from: Date())),
                "setlist_id": room.map(TeamJSON.id) ?? .null, "deleted": .bool(false), "pinned": .bool(false),
                "chart_version_id": chart.map(TeamJSON.id) ?? .null]))
            return id
        }
    }
    func replaceChat(_ id: UUID, body: String, deleted: Bool = false) {
        lock.withLock {
            guard let index = chatMessages.firstIndex(where: { $0["id"].uuid == id }), case .object(var fields) = chatMessages[index] else { return }
            chatRevision += 2; fields["body"] = .string(body); fields["deleted"] = .bool(deleted); fields["revision"] = .int(chatRevision)
            chatMessages[index] = .object(fields)
        }
    }
    private func chatVisible(_ row: TeamJSON) -> TeamJSON {
        guard case .object(var fields) = row else { return row }
        if row["deleted"].flag || chatBlocked.contains(row["author_id"].uuid ?? UUID()) {
            fields["body"] = .string(""); fields["chart_version_id"] = .null; fields["chart_title"] = .null
            if !row["deleted"].flag { fields["hidden"] = .bool(true) }
        }
        return .object(fields)
    }
    func setUser(_ value: UUID) { lock.withLock { user = value } }
    func addSong(_ value: TeamJSON) { lock.withLock { extraSongs.append(value) } }
    func catalogValue() -> TeamJSON {
        lock.withLock { .object(Dictionary(uniqueKeysWithValues: ["songs", "chart_versions", "assets", "setlists", "performance_items", "personal_preferences"].map { ($0, catalogRows($0)) }).merging(["team_id": .id(Self.team), "schema_version": .int(1), "next_cursor": .null]) { _, new in new }) }
    }
    func setOffline(_ value: Bool) { lock.withLock { offline = value } }
    func failCreations(_ value: Bool) { lock.withLock { failCreation = value } }
    func failCalls(_ value: Bool) { lock.withLock { failPublication = value } }
    func rejectInk(_ value: Bool) { lock.withLock { conflictInk = value } }
    func failHeads(_ value: Bool) { lock.withLock { failHeadReads = value } }
    func pause(_ path: String) { lock.withLock { pausedPath = path; pauseNextOnly = false } }
    func pauseNext(_ path: String) { lock.withLock { pausedPath = path; pauseNextOnly = true } }
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
        .object(["id": .id(Self.live), "church_id": .id(Self.church), "team_id": .id(Self.team), "setlist_id": .id(Self.setlist),
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
        if name == pausedPath { waiting.append(completion); if pauseNextOnly { pausedPath = nil; pauseNextOnly = false }; lock.unlock(); return }
        if let path = request.url?.path, request.httpMethod == "POST", let marker = path.range(of: "/worshipcue-private/") {
            let key = String(path[marker.upperBound...])
            if blobs[key] != nil { lock.unlock(); completion(409, .null); return }
            blobs[key] = Self.body(request); lock.unlock(); completion(200, .object([:])); return
        }
        let workflowNames = ["create_song", "stage_asset", "publish_chart_version", "create_setlist", "save_setlist"]
        let receiptKey = name + "/" + (p["command_id"].text ?? "none")
        if workflowNames.contains(name), p["command_id"].uuid != nil, let receipt = workflowReceipts[receiptKey] {
            lock.unlock(); completion(200, receipt); return
        }
        var result: TeamJSON = .null, status = 200
        switch name {
        case "create_song":
            result = .object(["id": .id(UUID()), "church_id": .id(Self.church), "team_id": .id(Self.team), "canonical_title": p["canonical_title"]]); extraSongs.append(result)
        case "create_setlist":
            result = .object(["id": .id(UUID()), "church_id": .id(Self.church), "team_id": .id(Self.team), "title": p["title"], "revision": .int(0)]); extraSetlists.append(result)
        case "save_setlist":
            if let index = extraSetlists.firstIndex(where: { $0["id"] == p["setlist_id"] }), case .object(var fields) = extraSetlists[index] {
                if fields["revision"] != p["base_revision"] { status = 409 }
                else {
                    fields["revision"] = .int((fields["revision"]?.integer ?? 0) + 1)
                    if p["title"].text != nil { fields["title"] = p["title"] }
                    extraSetlists[index] = .object(fields); result = extraSetlists[index]
                    extraItems.removeAll { $0["setlist_id"] == p["setlist_id"] }
                    extraItems += p["items"].list.map { item in
                        guard case .object(var fields) = item else { return .null }
                        fields["church_id"] = .id(Self.church); fields["team_id"] = .id(Self.team); fields["setlist_id"] = p["setlist_id"]; fields["active"] = .bool(true); return .object(fields)
                    }
                }
            } else { status = 404 }
        case "publish_chart_version":
            if let asset = assets.first(where: { $0["id"] == p["verified_pdf_asset_id"] }) {
                result = .object(["id": .id(UUID()), "church_id": .id(Self.church), "team_id": .id(Self.team), "song_id": p["song_id"],
                    "pdf_asset_id": asset["id"], "version_number": .int(1), "label": p["label"], "written_key": p["written_key"],
                    "page_manifest": asset["page_manifest"], "page_count": .int(Int64(asset["page_manifest"].list.count)), "published_at": .string("2026-10-08T00:00:00Z")]); charts.append(result)
            } else { status = 404 }
        case "otp": result = .object(["session": .string("synthetic-challenge"), "challenge": .string("EMAIL_OTP")])
        case "verify", "token":
            result = .object(["user": .object(["id": .id(user), "is_anonymous": .bool(false)]),
                "access_token": .string("synthetic-access"), "refresh_token": .string("synthetic-refresh"), "expires_in": .int(3600)])
        case "memberships": result = .array([.object(["user_id": .id(user), "church_id": .id(Self.church), "team_id": .id(Self.team), "role": .string(memberRole), "active": .bool(true)])] + extraMemberships)
        case "songs", "chart_versions", "assets", "setlists", "performance_items", "personal_preferences": result = catalogRows(name)
        case "get_team_catalog", "get_team_catalog_page":
            result = .object(Dictionary(uniqueKeysWithValues: ["songs", "chart_versions", "assets", "setlists", "performance_items", "personal_preferences"].map { ($0, catalogRows($0)) }).merging(["team_id": .id(Self.team), "schema_version": .int(1), "next_cursor": .null]) { _, new in new })
        case "set_personal_preference": preferences[user] = p["preferred_version_id"].uuid!; result = .object(["revision": .int(1)])
        case "create_church_and_default_team", "create_team":
            if failCreation { status = 503 }
            else { result = .object(["church_id": .id(Self.church), "team_id": .id(Self.team)]); if dropAfterPublication { offline = true } }
        case "get_team_roster": result = .object(["team_id": p["team_id"], "members": .array([.object(["user_id": .id(Self.userA), "display_name": .string("Synthetic A")]), .object(["user_id": .id(Self.userB), "display_name": .string("Synthetic B")])])])
        case "get_chat_rooms":
            let rooms: [TeamJSON] = [TeamJSON.null, .id(Self.setlist)].map { room in
                let key = room.text ?? "team", latest = chatMessages.filter { $0["setlist_id"] == room }.map { $0["revision"].integer ?? 0 }.max() ?? 0
                let read = chatRead[key] ?? 0
                let unread = chatMessages.filter { $0["setlist_id"] == room && ($0["revision"].integer ?? 0) > read && $0["author_id"].uuid != user && !$0["deleted"].flag && !chatBlocked.contains($0["author_id"].uuid ?? UUID()) }.count
                return .object(["setlist_id": room, "title": .string(key), "latest_revision": .int(latest), "read_revision": .int(read),
                    "unread_count": unknownUnread ? .null : .int(Int64(unread)), "unread_complete": .bool(!unknownUnread), "muted": .bool(chatMuted.contains(key))])
            }
            result = .object(["team_id": p["team_id"], "rooms": .array(rooms), "has_more": .bool(false), "blocked_author_ids": .array(chatBlocked.map(TeamJSON.id)), "block_revision": .int(blockRevision)])
        case "mark_chat_read": chatRead[p["setlist_id"].text ?? "team"] = p["revision"].integer ?? 0
        case "get_chat_snapshot":
            let rows = chatMessages.filter { $0["setlist_id"] == p["setlist_id"] }, latest = rows.map { $0["revision"].integer ?? 0 }.max() ?? 0
            result = .object(["team_id": p["team_id"], "setlist_id": p["setlist_id"], "revision": .int(latest), "messages": .array(rows.map(chatVisible)),
                "blocked_author_ids": .array(chatBlocked.map(TeamJSON.id)), "block_revision": .int(blockRevision), "reset": .bool(p["known_block_revision"].integer != blockRevision), "has_more": .bool(false)])
        case "edit_chat_message", "delete_chat_message", "pin_chat_message":
            if failChat { status = 503 }
            else if let index = chatMessages.firstIndex(where: { $0["id"] == p["message_id"] }), case .object(var fields) = chatMessages[index] {
                if let command = p["command_id"].uuid, chatReceipts.contains(command) { result = chatVisible(chatMessages[index]) }
                else if p["expected_revision"] != chatMessages[index]["revision"] { status = 409; result = .object(["message": .string("REVISION_CONFLICT")]) }
                else {
                    chatRevision += 1; fields["revision"] = .int(chatRevision)
                    if name == "edit_chat_message" { fields["body"] = p["body"]; fields["edited_at"] = .string(ISO8601DateFormatter().string(from: Date())) }
                    if name == "delete_chat_message" { fields["deleted"] = .bool(true); fields["body"] = .string(""); fields["chart_version_id"] = .null }
                    if name == "pin_chat_message" { fields["pinned"] = p["pinned"] }
                    chatMessages[index] = .object(fields); result = chatVisible(chatMessages[index]); if let command = p["command_id"].uuid { chatReceipts.insert(command) }
                }
            }
        case "mute_chat":
            if failChat { status = 503 }
            else { let key = p["setlist_id"].text ?? "team"; if p["muted"].flag { chatMuted.insert(key) } else { chatMuted.remove(key) }; result = .object(["muted": p["muted"]]) }
        case "block_chat_member":
            if failChat { status = 503 }
            else if let id = p["user_id"].uuid { if p["blocked"].flag { chatBlocked.insert(id) } else { chatBlocked.remove(id) }; blockRevision += 1; result = .object(["blocked": p["blocked"]]) }
        case "report_chat_message":
            if failChat { status = 503 }
            else {
                result = .object(["id": p["command_id"], "report_id": p["command_id"], "message_id": p["message_id"], "reporter_id": .id(user), "reason": p["reason"], "status": .string("open"), "revision": .int(1), "setlist_id": p["setlist_id"]])
                if !chatReports.contains(where: { $0["id"] == p["command_id"] }) { chatReports.append(result) }
            }
        case "get_chat_reports": result = .object(["team_id": p["team_id"], "reports": .array(chatReports.filter { $0["status"].text == "open" }), "has_more": .bool(false)])
        case "resolve_chat_report":
            if failChat { status = 503 }
            else if let index = chatReports.firstIndex(where: { $0["id"] == p["report_id"] }), case .object(var fields) = chatReports[index] {
                fields["status"] = p["status"]; fields["revision"] = .int(2); chatReports[index] = .object(fields); result = chatReports[index]
            }
        case "send_chat_message":
            if let prior = chatMessages.first(where: { $0["id"] == p["command_id"] }) { result = prior }
            else {
                chatRevision += 1
                result = .object(["id": p["command_id"], "author_id": .id(user), "body": p["body"], "revision": .int(chatRevision), "created_revision": .int(chatRevision),
                    "created_at": .string(ISO8601DateFormatter().string(from: Date())), "reply_to_id": p["reply_to_id"],
                    "setlist_id": p["setlist_id"], "deleted": .bool(false), "pinned": .bool(false), "chart_version_id": p["chart_version_id"]])
                chatMessages.append(result)
            }
        case "get_session_snapshot": result = snapshot(ended: ended, revision: revision)
        case "get_annotation_head":
            if let headStatus { status = headStatus }
            else if failHeadReads { status = 503 }
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
            result = .object(["id": .id(id), "church_id": .id(Self.church), "team_id": .id(Self.team), "storage_key": .string("synthetic/\(id)"), "sha256": p["sha256"], "bytes": p["expected_bytes"], "type": p["type"], "status": .string("staging")])
            assets.append(result)
        case "finalize-asset":
            if let index = assets.firstIndex(where: { $0["id"] == body["asset_id"] }), case .object(var fields) = assets[index] {
                if fields["type"]?.text == "pdf" {
                    let data = blobs[fields["storage_key"]?.text ?? ""]
                    guard let source = originals.first(where: { $0.value == data })?.key,
                          let chart = charts.first(where: { $0["id"].uuid == source }) else { lock.unlock(); completion(409, .null); return }
                    fields["page_manifest"] = chart["page_manifest"]; fields["page_count"] = chart["page_count"]
                }
                fields["status"] = .string("verified"); assets[index] = .object(fields); result = assets[index]
            } else { status = 404 }
        case "save_annotation_revision":
            if conflictInk { status = 400; result = .object(["message": .string("REVISION_CONFLICT")]) }
            else { result = .object(["revision_number": .int((p["parent_revision"].integer ?? 0) + 1)]) }
        case "preflight_manifest": result = .object(["setlist_id": .id(Self.setlist), "setlist_revision": .int(1), "charts": .array(charts), "annotation_heads": .array(heads.values.filter { $0["scope"].text == "team" }.sorted { $0["native_storage_key"].text! < $1["native_storage_key"].text! })])
        default: break
        }
        if status == 200, workflowNames.contains(name), p["command_id"].uuid != nil { workflowReceipts[receiptKey] = result }
        if status == 200, malformedResponses.remove(name) != nil { result = .null }
        if status == 200, lostResponses.remove(name) != nil { status = 0 }
        if status == 200, dropAfterPublication, ["publish_chart_version", "save_setlist"].contains(name) { offline = true }
        lock.unlock(); completion(status, result)
    }
}

@MainActor final class TeamWorkspaceTests: XCTestCase {
    private func expectTrue(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) { XCTAssertTrue(value, file: file, line: line) }
    private func expectFalse(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) { XCTAssertFalse(value, file: file, line: line) }
    private func setupWorkspace(provider: RemoteProvider = .supabase) async throws -> (TeamWorkspace, TeamFixture, URL, RemoteConfiguration, URLSession) {
        let fixture = TeamFixture()
        for (index, tuple) in [(TeamFixture.a1, TeamFixture.songA, "song_A_v1_G"), (TeamFixture.a2, TeamFixture.songA, "song_A_v2_G"), (TeamFixture.b1, TeamFixture.songB, "song_A_v3_A")].enumerated() {
            let source = try XCTUnwrap(Bundle.main.url(forResource: tuple.2, withExtension: "pdf", subdirectory: "pdfs"))
            let data = try Data(contentsOf: source), document = try XCTUnwrap(PDFDocument(data: data)), asset = UUID()
            let pages = try (0..<document.pageCount).map { try TeamWorkspace.jsonGeometry(document.page(at: $0)!.canonicalGeometry()) }
            fixture.originals[tuple.0] = data
            fixture.charts.append(.object(["id": .id(tuple.0), "church_id": .id(TeamFixture.church), "team_id": .id(TeamFixture.team), "song_id": .id(tuple.1), "version_number": .int(index == 1 ? 2 : 1), "label": .string(tuple.2), "written_key": .string("G"), "pdf_asset_id": .id(asset), "page_count": .int(Int64(document.pageCount)), "page_manifest": .array(pages), "published_at": .string("2026-10-08T00:00:00Z")]))
            fixture.assets.append(.object(["id": .id(asset), "church_id": .id(TeamFixture.church), "team_id": .id(TeamFixture.team), "storage_key": .string("synthetic/\(asset).pdf"), "sha256": .string(TeamWorkspace.hash(data)), "bytes": .int(Int64(data.count)), "type": .string("pdf"), "status": .string("verified")]))
        }
        TeamTestProtocol.fixture = fixture
        let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [TeamTestProtocol.self]
        let transport = URLSession(configuration: c), root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let config = try RemoteConfiguration(url: URL(string: "https://unit-\(UUID().uuidString.lowercased()).invalid")!,
            publishableKey: provider == .aws ? "" : "sb_publishable_synthetic", provider: provider)
        let team = TeamWorkspace(testRoot: root, configuration: config, transport: transport, realtimeEnabled: false)
        addTeardownBlock { @MainActor in fixture.release(); team.suspend(); _ = await team.logout(); transport.invalidateAndCancel(); TeamTestProtocol.fixture = nil; try? FileManager.default.removeItem(at: root) }
        if provider == .aws { expectTrue(await team.sendCode("synthetic@example.test")) }
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
        return .object(["church_id": .id(TeamFixture.church), "team_id": .id(TeamFixture.team), "chart_version_id": .id(chart), "page_index": .int(Int64(page)),
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
    func testTeamsWithinOneChurchHaveSeparateRolesCatalogsAndVaults() async throws {
        let (team, fixture, _, _, _) = try await setupWorkspace()
        expectTrue(await team.openVersion(TeamFixture.a1)); await team.reader?.turnPage(1); team.navigationChanged()
        let original = try XCTUnwrap(team.cache)
        let otherTeam = UUID()
        let membership = TeamJSON.object(["user_id": .id(TeamFixture.userA), "church_id": .id(TeamFixture.church),
            "team_id": .id(otherTeam), "role": .string("member"), "active": .bool(true)])
        fixture.extraMemberships = [membership]
        await team.chooseWorkspace(membership)
        XCTAssertEqual(team.selectedTeam, otherTeam); XCTAssertFalse(team.canLead); XCTAssertFalse(team.canAdmin)
        XCTAssertTrue(team.songs.isEmpty); XCTAssertTrue(team.versions.isEmpty); XCTAssertTrue(team.items.isEmpty)
        XCTAssertNil(team.reader); XCTAssertFalse(team.cache === original); XCTAssertTrue(try XCTUnwrap(team.cache).charts.isEmpty)
        let back = try XCTUnwrap(team.memberships.first { $0["team_id"].uuid == TeamFixture.team })
        await team.chooseWorkspace(back)
        expectTrue(await team.openVersion(TeamFixture.a1)); XCTAssertEqual(team.reader?.pageIndex, 1)
        XCTAssertTrue(team.canLead); XCTAssertTrue(team.canAdmin)
    }
    func testAWSLibraryRefreshUsesOneScopedCatalogAndPreservesReader() async throws {
        let (team, fixture, _, _, _) = try await setupWorkspace(provider: .aws)
        team.suspend()
        expectTrue(await team.openVersion(TeamFixture.a1)); await team.reader?.turnPage(1); team.navigationChanged()
        let reader = team.reader, before = fixture.recorded("get_team_catalog_page").count
        await team.refresh(); team.suspend()
        XCTAssertEqual(fixture.recorded("get_team_catalog_page").count, before + 1)
        XCTAssertEqual(fixture.recorded("get_team_catalog_page").last?["team_id"].uuid, TeamFixture.team)
        XCTAssertEqual(fixture.recorded("get_team_catalog_page").last?["selected_team_id"].uuid, TeamFixture.team)
        for name in ["songs", "chart_versions", "assets", "setlists", "performance_items", "personal_preferences"] {
            XCTAssertTrue(fixture.recorded(name).isEmpty, "AWS must refresh catalog rows in one request")
        }
        XCTAssertEqual(team.songs.count, 2); XCTAssertEqual(team.versions.count, 3)
        XCTAssertEqual(team.items.count, 2); XCTAssertEqual(team.preferredVersions[TeamFixture.songA], TeamFixture.a1)
        XCTAssertTrue(team.reader === reader); XCTAssertEqual(team.reader?.pageIndex, 1)
    }
    func testIncompleteAWSCatalogCannotEraseCachedLibrary() async throws {
        let (team, fixture, _, _, _) = try await setupWorkspace(provider: .aws)
        team.suspend()
        let songs = team.songs.map(\.value), versions = team.versions.map(\.value), items = team.items.map(\.value)
        fixture.pause("get_team_catalog_page")
        let refresh = Task { await team.refresh() }; try await waitPaused(fixture)
        fixture.release(200, .object(["songs": .array([])])); await refresh.value
        XCTAssertEqual(team.songs.map(\.value), songs); XCTAssertEqual(team.versions.map(\.value), versions); XCTAssertEqual(team.items.map(\.value), items)
        XCTAssertNotNil(team.error)
    }
    func testAWSMetadataHintsCoalesceWithoutLiveSessionAndPreserveReaderPage() async throws {
        let (team, fixture, _, _, _) = try await setupWorkspace(provider: .aws)
        team.suspend()
        expectTrue(await team.openVersion(TeamFixture.a1)); await team.reader?.turnPage(1); team.navigationChanged()
        let reader = team.reader, newSong = UUID(), before = fixture.recorded("get_team_catalog_page").count
        XCTAssertNil(team.live)
        fixture.addSong(.object(["id": .id(newSong), "church_id": .id(TeamFixture.church), "team_id": .id(TeamFixture.team), "canonical_title": .string("New synthetic team chart")]))
        fixture.pause("get_team_catalog_page")
        await team.hintReceived(team.scopeID); try await waitPaused(fixture)
        for _ in 0..<10 { await team.hintReceived(team.scopeID) }
        XCTAssertEqual(fixture.recorded("get_team_catalog_page").count, before + 1)
        fixture.release(200, fixture.catalogValue())
        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        while (!team.songs.contains { $0.id == newSong } || fixture.recorded("get_team_catalog_page").count < before + 2 || team.busy), ContinuousClock().now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(team.songs.contains { $0.id == newSong })
        XCTAssertEqual(fixture.recorded("get_team_catalog_page").count, before + 2, "Burst hints coalesce into one pending refresh")
        XCTAssertTrue(team.reader === reader); XCTAssertEqual(team.reader?.pageIndex, 1); XCTAssertNil(team.live)
        XCTAssertTrue(fixture.recorded("acknowledge_open").isEmpty)
    }
    func testChatDraftSurvivesOfflineRelaunchWithoutAutomaticSendAndRetryKeepsCommand() async throws {
        let (team, fixture, root, config, transport) = try await setupWorkspace()
        await team.openChat(); team.updateChatComposer("Synthetic rehearsal message")
        fixture.setOffline(true); expectFalse(await team.sendChat())
        let draft = try XCTUnwrap(team.chatDrafts.first), attempts = fixture.recorded("send_chat_message")
        XCTAssertEqual(attempts.count, 1); XCTAssertEqual(attempts.first?["command_id"].uuid, draft.id)
        team.suspend()
        let restored = TeamWorkspace(testRoot: root, configuration: config, transport: transport, realtimeEnabled: false)
        await restored.restore(); await restored.openChat()
        XCTAssertEqual(restored.chatDrafts, [draft]); XCTAssertEqual(fixture.recorded("send_chat_message").count, 1)
        fixture.setOffline(false); await restored.refresh(); XCTAssertEqual(fixture.recorded("send_chat_message").count, 1)
        expectTrue(await restored.retryChat(draft)); XCTAssertTrue(restored.chatDrafts.isEmpty)
        let retries = fixture.recorded("send_chat_message"); XCTAssertEqual(retries.count, 2); XCTAssertEqual(retries[0], retries[1])
        XCTAssertEqual(restored.chatMessages.first?.value["body"].text, draft.body)
        restored.suspend(); _ = await restored.logout()
    }
    func testLateChatSnapshotCannotEnterAnotherTeamsState() async throws {
        let (team, fixture, _, _, _) = try await setupWorkspace()
        fixture.pause("get_chat_snapshot")
        let loading = Task { await team.openChat() }; try await waitPaused(fixture)
        let otherTeam = UUID(), membership = TeamJSON.object(["user_id": .id(TeamFixture.userA), "church_id": .id(TeamFixture.church),
            "team_id": .id(otherTeam), "role": .string("member"), "active": .bool(true)])
        fixture.extraMemberships = [membership]; await team.chooseWorkspace(membership)
        fixture.release(200, .object(["revision": .int(1), "messages": .array([.object(["id": .id(UUID()), "author_id": .id(TeamFixture.userA),
            "body": .string("Old team message"), "revision": .int(1), "setlist_id": .null, "deleted": .bool(false)])])]))
        await loading.value; XCTAssertEqual(team.selectedTeam, otherTeam); XCTAssertTrue(team.chatMessages.isEmpty); XCTAssertNil(team.chatError)
    }
    func testChatReconciliationNeverChangesReaderPageOrPendingCue() async throws {
        let (team, fixture, _, _, _) = try await setupWorkspace()
        expectTrue(await team.openVersion(TeamFixture.a1)); await team.reader?.turnPage(1); team.navigationChanged()
        let call = fixture.call(1); fixture.deliver(call); expectTrue(await team.joinSession(TeamFixture.live))
        let reader = team.reader; await team.openChat(); team.updateChatComposer("Synthetic message")
        expectTrue(await team.sendChat())
        XCTAssertTrue(team.reader === reader); XCTAssertEqual(team.reader?.current?.id, TeamFixture.a1)
        XCTAssertEqual(team.reader?.pageIndex, 1); XCTAssertEqual(team.pending?.id, call["id"].uuid)
        XCTAssertTrue(fixture.recorded("acknowledge_open").isEmpty); XCTAssertTrue(fixture.recorded("publish_call").isEmpty)
    }

    func testExplicitCreationRetryUsesDurableCommandIdentity() async throws {
        let (team, fixture, root, config, transport) = try await setupWorkspace()
        fixture.failCreations(true)
        expectFalse(await team.createWorkspace("Synthetic church"))
        let first = try XCTUnwrap(fixture.recorded("create_church_and_default_team").first)
        team.suspend()
        let restored = TeamWorkspace(testRoot: root, configuration: config, transport: transport, realtimeEnabled: false)
        await restored.restore(); fixture.failCreations(false)
        expectTrue(await restored.createWorkspace("Synthetic church"))
        let retry = try XCTUnwrap(fixture.recorded("create_church_and_default_team").last)
        XCTAssertEqual(first, retry); XCTAssertNotNil(first["command_id"].uuid)
        fixture.failCreations(true); expectFalse(await restored.createTeam("Synthetic team"))
        fixture.failCreations(false); expectTrue(await restored.createTeam("Synthetic team"))
        let teams = fixture.recorded("create_team"); XCTAssertEqual(teams.count, 2); XCTAssertEqual(teams[0], teams[1])
        restored.suspend(); _ = await restored.logout()
    }

    func testChatUnreadRefreshesClosedRoomsAndReadWaitsForDisplayedPersistedSnapshot() async throws {
        let (team, fixture, _, _, _) = try await setupWorkspace(provider: .aws)
        _ = fixture.addChat("Synthetic unread")
        await team.refreshChat()
        XCTAssertEqual(team.chatUnreadSummary, "1"); XCTAssertTrue(fixture.recorded("mark_chat_read").isEmpty)
        await team.openChat()
        XCTAssertEqual(team.chatMessages.count, 1); XCTAssertTrue(fixture.recorded("mark_chat_read").isEmpty)
        await team.markChatDisplayed(lastMessageID: team.chatMessages.last?.id, revision: team.chatSnapshotRevision)
        XCTAssertEqual(fixture.recorded("mark_chat_read").count, 1); XCTAssertNil(team.chatUnreadSummary)
        let displayedID = team.chatMessages.last?.id, displayedRevision = team.chatSnapshotRevision
        _ = fixture.addChat("Not displayed yet"); await team.refreshChat()
        await team.markChatDisplayed(lastMessageID: displayedID, revision: displayedRevision)
        XCTAssertEqual(fixture.recorded("mark_chat_read").count, 1, "A previously visible last row cannot mark a new unseen row read")
        team.closeChat(); _ = fixture.addChat("Second unread", room: TeamFixture.setlist)
        await team.refreshChat(); XCTAssertEqual(team.chatUnreadLabel(TeamFixture.setlist), "1")
        fixture.setUnknownUnread(true); await team.refreshChatRooms()
        XCTAssertEqual(team.chatUnreadLabel(TeamFixture.setlist), String(localized: "새 대화"))
        XCTAssertEqual(team.chatUnreadSummary, String(localized: "새 대화"))
        await team.openChat(setlistID: TeamFixture.setlist); expectTrue(await team.muteChat())
        XCTAssertTrue(team.chatMuted); XCTAssertNil(team.chatUnreadLabel(TeamFixture.setlist))
    }
    func testFailedChatEditRetainsTextAndStableCommandAcrossRelaunchWithoutReplay() async throws {
        let (team, fixture, root, config, transport) = try await setupWorkspace()
        await team.openChat(); team.updateChatComposer("Original text"); expectTrue(await team.sendChat())
        let row = try XCTUnwrap(team.chatMessages.first)
        fixture.failChatActions(true); expectFalse(await team.editChat(row, body: "Edited text retained offline"))
        let action = try XCTUnwrap(team.chatActions.first)
        XCTAssertEqual(action.payload["body"]?.text, "Edited text retained offline")
        let first = try XCTUnwrap(fixture.recorded("edit_chat_message").first)
        team.suspend()
        let restored = TeamWorkspace(testRoot: root, configuration: config, transport: transport, realtimeEnabled: false)
        await restored.restore(); await restored.openChat()
        XCTAssertEqual(restored.chatActions, [action]); await restored.refreshChat()
        XCTAssertEqual(fixture.recorded("edit_chat_message").count, 1, "Refresh must never replay a mutation")
        fixture.failChatActions(false); expectTrue(await restored.retryChatAction(action))
        XCTAssertEqual(fixture.recorded("edit_chat_message").last, first); XCTAssertTrue(restored.chatActions.isEmpty)
        XCTAssertEqual(restored.chatMessages.first?.value["body"].text, "Edited text retained offline")
        restored.suspend(); _ = await restored.logout()
    }
    func testLateChatSnapshotAfterRoomRoundTripCannotReplaceCurrentConversation() async throws {
        let (team, fixture, _, _, _) = try await setupWorkspace()
        _ = fixture.addChat("Current durable message")
        await team.openChat(); fixture.pauseNext("get_chat_snapshot")
        let pending = Task { await team.refreshChat() }; try await waitPaused(fixture)
        await team.openChat(setlistID: TeamFixture.setlist); await team.openChat()
        fixture.release(200, .object(["revision": .int(1), "messages": .array([.object(["id": .id(UUID()), "author_id": .id(TeamFixture.userB),
            "body": .string("Stale response"), "setlist_id": .null, "revision": .int(1), "deleted": .bool(false)])])]))
        await pending.value
        await team.refreshChat()
        XCTAssertEqual(team.chatMessages.map { $0.value["body"].text }, ["Current durable message"])
        XCTAssertTrue(fixture.recorded("mark_chat_read").isEmpty)
    }
    func testBlockImmediatelyRedactsEveryCachedRoomAndUnblockReloadsOriginalFromServer() async throws {
        let (team, fixture, root, _, _) = try await setupWorkspace()
        _ = fixture.addChat("Sensitive team message", chart: TeamFixture.a1)
        _ = fixture.addChat("Sensitive setlist message", room: TeamFixture.setlist, chart: TeamFixture.a2)
        await team.openChat(); await team.openChat(setlistID: TeamFixture.setlist)
        fixture.failChatActions(true)
        expectFalse(await team.blockChatMember(TeamFixture.userB, blocked: true))
        XCTAssertTrue(team.chatBlockedAuthors.contains(TeamFixture.userB))
        XCTAssertEqual(team.chatMessages.first?.value["body"].text, ""); XCTAssertNil(team.chatMessages.first?.value["chart_version_id"].uuid)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        for case let file as URL in enumerator where file.lastPathComponent.hasPrefix("chat-") && file.pathExtension == "json" {
            let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
            XCTAssertFalse(text.contains("Sensitive team message")); XCTAssertFalse(text.contains("Sensitive setlist message"))
        }
        await team.openChat(); XCTAssertEqual(team.chatMessages.first?.value["body"].text, "")
        fixture.failChatActions(false); expectTrue(await team.blockChatMember(TeamFixture.userB, blocked: false))
        XCTAssertFalse(team.chatBlockedAuthors.contains(TeamFixture.userB))
        XCTAssertEqual(team.chatMessages.first?.value["body"].text, "Sensitive team message")
        XCTAssertEqual(team.chatMessages.first?.value["chart_version_id"].uuid, TeamFixture.a1)
    }
    func testAuthorAndLeaderChatGatesAndDeletedReplyQuoteRemainSafe() async throws {
        let (team, fixture, _, _, _) = try await setupWorkspace()
        let otherID = fixture.addChat("Other author message")
        await team.openChat(); let other = try XCTUnwrap(team.chatMessages.first { $0.id == otherID })
        fixture.setMemberRole("member"); await team.refresh()
        expectFalse(await team.editChat(other, body: "Unauthorized")); expectFalse(await team.deleteChat(other))
        XCTAssertTrue(fixture.recorded("edit_chat_message").isEmpty); XCTAssertTrue(fixture.recorded("delete_chat_message").isEmpty)
        fixture.setMemberRole("member"); await team.refresh(); expectFalse(await team.pinChat(other))
        await team.refreshChatReports(); XCTAssertTrue(fixture.recorded("get_chat_reports").isEmpty)
        expectTrue(await team.reportChat(other, reason: "Synthetic review reason"))
        fixture.setMemberRole("leader"); await team.refresh(); await team.refreshChatReports()
        let report = try XCTUnwrap(team.chatReports.first); expectTrue(await team.resolveChatReport(report, dismissed: true))
        XCTAssertTrue(team.chatReports.isEmpty); expectTrue(await team.pinChat(other))
        XCTAssertTrue(team.chatMessages.first { $0.id == otherID }?.value["pinned"].flag == true)
        let moderated = try XCTUnwrap(team.chatMessages.first { $0.id == otherID })
        expectTrue(await team.deleteChat(moderated)); XCTAssertTrue(team.chatMessages.first { $0.id == otherID }?.value["deleted"].flag == true)
        team.updateChatComposer("Own message to delete"); expectTrue(await team.sendChat())
        let own = try XCTUnwrap(team.chatMessages.first { $0.value["author_id"].uuid == TeamFixture.userA })
        expectTrue(await team.deleteChat(own))
        let deleted = try XCTUnwrap(team.chatMessages.first { $0.id == own.id })
        XCTAssertEqual(team.chatMessageText(deleted), String(localized: "삭제된 메시지")); XCTAssertEqual(deleted.value["body"].text, "")
    }
    func testChartLinkDraftAndPreviewPreserveReaderUntilExplicitOpenAndRejectForeignChart() async throws {
        let (team, fixture, _, _, _) = try await setupWorkspace()
        expectTrue(await team.openVersion(TeamFixture.a1)); await team.reader?.turnPage(1); team.navigationChanged()
        let reader = team.reader; await team.openChat(); team.setChatChart(TeamFixture.a2)
        let preview = try await team.previewChatChart(TeamFixture.a2)
        XCTAssertGreaterThan(preview.pageCount, 0); XCTAssertTrue(team.reader === reader)
        XCTAssertEqual(team.reader?.current?.id, TeamFixture.a1); XCTAssertEqual(team.reader?.pageIndex, 1)
        do { _ = try await team.previewChatChart(UUID()); XCTFail("Foreign chart must be rejected") } catch RemoteError.forbidden {} catch { XCTFail("Unexpected error") }
        team.updateChatComposer("Synthetic linked chart"); expectTrue(await team.sendChat())
        XCTAssertEqual(fixture.recorded("send_chat_message").last?["chart_version_id"].uuid, TeamFixture.a2)
        XCTAssertEqual(team.reader?.pageIndex, 1); XCTAssertEqual(team.reader?.current?.id, TeamFixture.a1)
        expectTrue(await team.openChatChart(TeamFixture.a2)); XCTAssertEqual(team.reader?.current?.id, TeamFixture.a2)
        XCTAssertTrue(fixture.recorded("publish_call").isEmpty); XCTAssertTrue(fixture.recorded("acknowledge_open").isEmpty)
    }
    func testReplyAndChartComposerContextSurviveRoomSwitchAndOfflineSendRetry() async throws {
        let (team, fixture, _, _, _) = try await setupWorkspace()
        let reply = fixture.addChat("Original reply target")
        await team.openChat(); team.setChatReply(reply); team.setChatChart(TeamFixture.a1); team.updateChatComposer("Reply with chart")
        await team.openChat(setlistID: TeamFixture.setlist); XCTAssertNil(team.chatComposerReplyID); XCTAssertNil(team.chatComposerChartID)
        await team.openChat(); XCTAssertEqual(team.chatComposer, "Reply with chart"); XCTAssertEqual(team.chatComposerReplyID, reply); XCTAssertEqual(team.chatComposerChartID, TeamFixture.a1)
        fixture.setOffline(true); expectFalse(await team.sendChat())
        let draft = try XCTUnwrap(team.chatDrafts.first); XCTAssertEqual(draft.replyToID, reply); XCTAssertEqual(draft.chartVersionID, TeamFixture.a1)
        fixture.setOffline(false); await team.refreshChat(); XCTAssertEqual(fixture.recorded("send_chat_message").count, 1)
        expectTrue(await team.retryChat(draft)); let sent = fixture.recorded("send_chat_message")
        XCTAssertEqual(sent.count, 2); XCTAssertEqual(sent[0], sent[1]); XCTAssertEqual(sent.last?["reply_to_id"].uuid, reply)
    }

    func testDelayedMutationReceiptCannotResurrectNewerDeletedMessage() async throws {
        let (team, fixture, _, _, _) = try await setupWorkspace()
        let id = fixture.addChat("Initial own text", author: TeamFixture.userA)
        await team.openChat(); let original = try XCTUnwrap(team.chatMessages.first)
        fixture.pause("edit_chat_message")
        let editing = Task { await team.editChat(original, body: "Delayed edited text") }; try await waitPaused(fixture)
        fixture.replaceChat(id, body: "", deleted: true); await team.refreshChat()
        XCTAssertTrue(team.chatMessages.first?.value["deleted"].flag == true)
        fixture.release(200, .object(["id": .id(id), "team_id": .id(TeamFixture.team), "author_id": .id(TeamFixture.userA),
            "setlist_id": .null, "revision": .int(2), "created_revision": .int(1), "deleted": .bool(false), "body": .string("Delayed edited text")]))
        expectTrue(await editing.value)
        XCTAssertEqual(team.chatMessages.first?.value["body"].text, ""); XCTAssertTrue(team.chatMessages.first?.value["deleted"].flag == true)
        XCTAssertTrue(team.chatActions.isEmpty)
    }

    func testRenderedChatMarksOnlyVisiblePersistedMessagesAndPreservesMusicStand() async throws {
        let (team, fixture, _, _, _) = try await setupWorkspace()
        expectTrue(await team.openVersion(TeamFixture.a1)); await team.reader?.turnPage(1); team.navigationChanged()
        _ = fixture.addChat("이번 예배에서 마지막 후렴을 한 번 더 연주해요.", chart: TeamFixture.a2)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene), host = UIHostingController(rootView: TeamChatView(team: team))
        window.frame = scene.coordinateSpace.bounds; window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible(); team.closeChat() }
        let deadline = ContinuousClock().now.advanced(by: .seconds(8))
        while fixture.recorded("mark_chat_read").isEmpty, ContinuousClock().now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(fixture.recorded("mark_chat_read").count, 1, "Actual viewport geometry must qualify the persisted visible row")
        XCTAssertEqual(team.reader?.current?.id, TeamFixture.a1); XCTAssertEqual(team.reader?.pageIndex, 1)
        host.view.layoutIfNeeded()
        var rendered = false
        let image = UIGraphicsImageRenderer(size: host.view.bounds.size).image { _ in rendered = host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
        XCTAssertTrue(rendered); XCTAssertGreaterThan(image.size.width, 100); XCTAssertGreaterThan(image.size.height, 100)
        let attachment = XCTAttachment(image: image); attachment.name = "Build7 team chat rendered on iPad"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertTrue(fixture.recorded("publish_call").isEmpty); XCTAssertTrue(fixture.recorded("acknowledge_open").isEmpty)
    }

    func testDebugTestRootsNeverRestoreAnotherRootsTokensDeviceOrReaderPreferences() async throws {
        let (team, fixture, root, config, transport) = try await setupWorkspace()
        expectTrue(await team.openVersion(TeamFixture.a1)); await team.reader?.turnPage(1); team.navigationChanged()
        let otherRoot = root.appendingPathComponent("another-isolated-run")
        let isolated = TeamWorkspace(testRoot: otherRoot, configuration: config, transport: transport, realtimeEnabled: false)
        let priorRequests = fixture.recorded("memberships").count
        await isolated.restore(); XCTAssertNil(isolated.session); XCTAssertNil(isolated.reader)
        XCTAssertEqual(fixture.recorded("memberships").count, priorRequests, "An isolated host must not restore the normal account or make its requests")
        XCTAssertNotEqual(isolated.deviceID, team.deviceID)
        team.suspend()
        let returning = TeamWorkspace(testRoot: root, configuration: config, transport: transport, realtimeEnabled: false)
        await returning.restore(); XCTAssertEqual(returning.session?.userID, TeamFixture.userA)
        XCTAssertEqual(returning.reader?.current?.id, TeamFixture.a1); XCTAssertEqual(returning.reader?.pageIndex, 1)
        XCTAssertEqual(returning.deviceID, team.deviceID)
        returning.suspend(); _ = await returning.logout()
    }

    func testPDFAmbiguousResponsesRetryFrozenCommandsWithoutDuplicateSongsAssetsOrVersions() async throws {
        for lost in ["create_song", "stage_asset", "finalize-asset", "publish_chart_version"] {
            let (team, fixture, root, config, transport) = try await setupWorkspace()
            let cache = try XCTUnwrap(team.cache)
            expectTrue(await team.openVersion(TeamFixture.a1, page: 1))
            let source = try cache.sourceBytes(TeamFixture.a1)
            fixture.loseResponseOnce(lost)
            expectFalse(await team.publish(cache, versionID: TeamFixture.a1, songID: nil))
            XCTAssertEqual(team.pendingPublications.count, 1, lost)
            let folder = try team.operationDirectory().appendingPathComponent("pending-publications")
            let frozen = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first { $0.pathExtension == "pdf" })
            XCTAssertEqual(try Data(contentsOf: frozen), source, "Retry must retain immutable original PDF bytes")
            team.suspend()
            let returning = TeamWorkspace(testRoot: root, configuration: config, transport: transport, realtimeEnabled: false)
            await returning.restore()
            let beforeRetry = fixture.recorded("publish_chart_version").count
            XCTAssertEqual(returning.pendingPublications.count, 1)
            await returning.refresh(); XCTAssertEqual(fixture.recorded("publish_chart_version").count, beforeRetry, "Reconnect must never replay publishing")
            expectTrue(await returning.retryPublication(try XCTUnwrap(returning.pendingPublications.first)))
            XCTAssertEqual(fixture.createdSongCount, 1, lost); XCTAssertEqual(fixture.publishedChartCount, 1, lost)
            for name in ["create_song", "stage_asset", "publish_chart_version"] {
                let requests = fixture.recorded(name)
                XCTAssertEqual(Set(requests.compactMap { $0["command_id"].uuid }).count, 1, "\(lost): \(name)")
                if requests.count > 1 { XCTAssertTrue(requests.dropFirst().allSatisfy { $0 == requests[0] }, "Frozen payload changed") }
            }
            XCTAssertEqual(returning.reader?.current?.id, TeamFixture.a1); XCTAssertEqual(returning.reader?.pageIndex, 1)
            XCTAssertTrue(returning.pendingPublications.isEmpty)
            returning.suspend(); _ = await returning.logout()
        }
    }
    func testNewSetlistTimeoutAfterCreateOrSaveReusesIdentityAndCASCommand() async throws {
        for lost in ["create_setlist", "save_setlist"] {
            let (team, fixture, _, _, _) = try await setupWorkspace()
            let item = TeamItemDraft(id: UUID(), versionID: TeamFixture.a1, key: "G", standby: false)
            fixture.loseResponseOnce(lost)
            expectFalse(await team.saveSetlist(id: nil, title: "Synthetic new service", revision: 0, entries: [item]))
            XCTAssertEqual(fixture.createdSetlistCount, 1)
            let before = fixture.recorded("save_setlist").count
            await team.refresh(); XCTAssertEqual(fixture.recorded("save_setlist").count, before)
            expectTrue(await team.retryPublication(try XCTUnwrap(team.pendingPublications.first)))
            XCTAssertEqual(fixture.createdSetlistCount, 1)
            XCTAssertEqual(team.items.filter { $0.id == item.id }.count, 1)
            for name in ["create_setlist", "save_setlist"] {
                let commands = fixture.recorded(name)
                XCTAssertEqual(Set(commands.compactMap { $0["command_id"].uuid }).count, 1)
                if commands.count > 1 { XCTAssertEqual(commands.first, commands.last) }
            }
            XCTAssertTrue(team.pendingPublications.isEmpty)
        }
    }
    func testLocalSetlistRetryRetainsFrozenCloudItemIDs() async throws {
        let (team, fixture, _, _, _) = try await setupWorkspace()
        let localItem = SetlistItem(songID: TeamFixture.songA, versionID: TeamFixture.a1, performanceKey: "G")
        let local = LocalSetlist(title: "Synthetic local rehearsal", items: [localItem])
        fixture.loseResponseOnce("save_setlist")
        expectFalse(await team.publishSetlist(local, mapping: [TeamFixture.a1: TeamFixture.a1]))
        expectTrue(await team.publishSetlist(local, mapping: [TeamFixture.a1: TeamFixture.a1]))
        let commands = fixture.recorded("save_setlist")
        XCTAssertEqual(commands.count, 2); XCTAssertEqual(commands.first, commands.last)
        XCTAssertNotEqual(commands[0]["items"].list.first?["id"].uuid, localItem.id)
        XCTAssertEqual(fixture.createdSetlistCount, 1); XCTAssertEqual(local.items, [localItem])
    }
    func testAcknowledgedPublicationWithLostCatalogRefreshOnlyRefreshesOnExplicitRetry() async throws {
        let (team, fixture, _, _, _) = try await setupWorkspace()
        fixture.dropCatalogAfterPublication(true)
        expectTrue(await team.publish(try XCTUnwrap(team.cache), versionID: TeamFixture.a1, songID: TeamFixture.songA))
        let pending = try XCTUnwrap(team.pendingPublications.first)
        XCTAssertTrue(pending.value["completed"].flag)
        XCTAssertEqual(fixture.publishedChartCount, 1)
        fixture.dropCatalogAfterPublication(false); fixture.setOffline(false)
        await team.refresh(); XCTAssertEqual(fixture.recorded("publish_chart_version").count, 1)
        expectTrue(await team.retryPublication(pending))
        XCTAssertEqual(fixture.recorded("publish_chart_version").count, 1); XCTAssertEqual(fixture.publishedChartCount, 1)
        XCTAssertTrue(team.pendingPublications.isEmpty)
    }
    func testChangedPendingSetlistRequiresExplicitRetryOrDiscardAndPreservesOriginal() async throws {
        let (team, fixture, _, _, _) = try await setupWorkspace()
        let item = TeamItemDraft(id: UUID(), versionID: TeamFixture.a1, key: "G", standby: false)
        fixture.loseResponseOnce("create_setlist")
        expectFalse(await team.saveSetlist(id: nil, title: "Original request", revision: 0, entries: [item]))
        expectFalse(await team.saveSetlist(id: nil, title: "Changed request", revision: 0, entries: [item]))
        XCTAssertEqual(fixture.createdSetlistCount, 1)
        let row = try XCTUnwrap(team.pendingPublications.first); XCTAssertEqual(row.value["title"].text, "Original request")
        expectTrue(await team.retryPublication(row)); XCTAssertEqual(fixture.createdSetlistCount, 1)
    }
    func testCachedChartOpensOnFirstTapWhenNetworkDropsWithoutSuspending() async throws {
        let (team, fixture, _, _, _) = try await setupWorkspace()
        XCTAssertTrue(team.online); fixture.setOffline(true)
        expectTrue(await team.openVersion(TeamFixture.a1, page: 1))
        XCTAssertFalse(team.online); XCTAssertEqual(team.reader?.current?.id, TeamFixture.a1); XCTAssertEqual(team.reader?.pageIndex, 1)
        XCTAssertNil(team.error); XCTAssertTrue(fixture.recorded("save_annotation_revision").isEmpty)
    }
    func testCachedChartDoesNotOpenThroughAuthorizationFailure() async throws {
        for status in [401, 403] {
            let (team, fixture, _, _, _) = try await setupWorkspace()
            fixture.denyPersonalHeads(status)
            expectFalse(await team.openVersion(TeamFixture.a1))
            XCTAssertNil(team.reader, "A verified PDF must not bypass an authorization failure")
        }
    }

    func testMalformedPublishAcknowledgementKeepsFrozenRequestAfterCommit() async throws {
        for operation in ["publish_chart_version", "save_setlist"] {
            let (team, fixture, _, _, _) = try await setupWorkspace()
            fixture.malformedResponseOnce(operation)
            if operation == "publish_chart_version" {
                expectFalse(await team.publish(try XCTUnwrap(team.cache), versionID: TeamFixture.a1, songID: TeamFixture.songA))
                XCTAssertEqual(fixture.publishedChartCount, 1)
            } else {
                expectFalse(await team.saveSetlist(id: nil, title: "Synthetic service", revision: 0,
                    entries: [TeamItemDraft(id: UUID(), versionID: TeamFixture.a1, key: "G", standby: false)]))
                XCTAssertEqual(fixture.createdSetlistCount, 1)
            }
            let row = try XCTUnwrap(team.pendingPublications.first); XCTAssertFalse(row.value["completed"].flag)
            expectTrue(await team.retryPublication(row))
            let commands = fixture.recorded(operation); XCTAssertEqual(commands.count, 2); XCTAssertEqual(commands.first, commands.last)
            XCTAssertTrue(team.pendingPublications.isEmpty)
        }
    }

    func testAcknowledgedWorkspaceCreationDoesNotCreateAgainAfterLostCatalogRefresh() async throws {
        let (team, fixture, root, config, transport) = try await setupWorkspace()
        fixture.dropCatalogAfterPublication(true)
        expectTrue(await team.createWorkspace("Synthetic church", memberDisplayName: "Synthetic member"))
        XCTAssertEqual(fixture.recorded("create_church_and_default_team").count, 1)
        team.suspend(); fixture.dropCatalogAfterPublication(false); fixture.setOffline(false)
        let returning = TeamWorkspace(testRoot: root, configuration: config, transport: transport, realtimeEnabled: false)
        await returning.restore()
        expectTrue(await returning.createWorkspace("Synthetic church", memberDisplayName: "Synthetic member"))
        XCTAssertEqual(fixture.recorded("create_church_and_default_team").count, 1, "Acknowledged creation must only reconcile metadata")
        returning.suspend(); _ = await returning.logout()
    }

    func testExplicitCachedCueOpenSurvivesFirstNetworkDropWithoutSendingAcknowledgement() async throws {
        let (team, fixture, _, _, _) = try await setupWorkspace()
        let call = fixture.call(1); fixture.deliver(call); expectTrue(await team.joinSession(TeamFixture.live))
        fixture.setOffline(true)
        expectTrue(await team.accept(try call.call()))
        XCTAssertEqual(team.reader?.current?.id, TeamFixture.a1); XCTAssertFalse(team.online)
        XCTAssertTrue(fixture.recorded("acknowledge_open").isEmpty)
    }
    func testExplicitChatChartOpenUsesVerifiedCacheOnFirstNetworkDrop() async throws {
        let (team, fixture, _, _, _) = try await setupWorkspace()
        await team.openChat()
        fixture.setOffline(true)
        expectTrue(await team.openChatChart(TeamFixture.a1))
        XCTAssertEqual(team.reader?.current?.id, TeamFixture.a1); XCTAssertFalse(team.online)
        XCTAssertTrue(fixture.recorded("acknowledge_open").isEmpty)
    }

    func testLateInvalidCatalogRowCannotPartiallyReplacePublishedMetadataOrDiskCache() async throws {
        let (team, fixture, _, _, _) = try await setupWorkspace(provider: .aws)
        team.suspend()
        let songs = team.songs.map(\.value), versions = team.versions.map(\.value), items = team.items.map(\.value), cache = team.cache
        let file = try team.operationDirectory().appendingPathComponent("team-catalog.json"), before = try Data(contentsOf: file)
        guard case .object(var catalog) = fixture.catalogValue(), case .object(var song) = songs[0] else { return XCTFail("Missing synthetic catalog") }
        song["canonical_title"] = .string("Must not leak from partial parsing")
        catalog["songs"] = .array([.object(song)] + songs.dropFirst())
        catalog["performance_items"] = .array(items + [.object(["id": .string("invalid-UUID"), "church_id": .id(TeamFixture.church), "team_id": .id(TeamFixture.team)])])
        fixture.pause("get_team_catalog_page"); let refresh = Task { await team.refresh() }; try await waitPaused(fixture)
        fixture.release(200, .object(catalog)); await refresh.value
        XCTAssertNotNil(team.error); XCTAssertEqual(team.songs.map(\.value), songs); XCTAssertEqual(team.versions.map(\.value), versions)
        XCTAssertEqual(team.items.map(\.value), items); XCTAssertTrue(team.cache === cache); XCTAssertEqual(try Data(contentsOf: file), before)
    }
    func testForeignTeamCatalogRowAndBrokenReferencesAreRejectedWithoutErasingCache() async throws {
        let (team, fixture, _, _, _) = try await setupWorkspace(provider: .aws)
        team.suspend(); let songs = team.songs.map(\.value), versions = team.versions.map(\.value)
        for foreign in [true, false] {
            guard case .object(var catalog) = fixture.catalogValue(), case .object(var version) = versions[0] else { return XCTFail("Missing synthetic catalog") }
            if foreign { version["team_id"] = .id(UUID()) }
            else { version["song_id"] = .id(UUID()) }
            catalog["chart_versions"] = .array([.object(version)] + versions.dropFirst())
            fixture.pause("get_team_catalog_page"); let refresh = Task { await team.refresh() }; try await waitPaused(fixture)
            fixture.release(200, .object(catalog)); await refresh.value
            XCTAssertNotNil(team.error); XCTAssertEqual(team.songs.map(\.value), songs); XCTAssertEqual(team.versions.map(\.value), versions)
        }
    }

}
