import SwiftUI
import PDFKit
import PencilKit
import CryptoKit
import Security
import Combine
import WorshipCueCore
import WorshipCueLocal
import WorshipCueRemote

typealias TeamJSON = RemoteJSON

struct TeamRow: Identifiable {
    let id: UUID
    let value: TeamJSON
    init(_ value: TeamJSON) throws { id = try value.requiredID("id"); self.value = value }
}

struct TeamChatDraft: Identifiable, Codable, Equatable {
    let id: UUID
    let body: String
    let setlistID: UUID?
    let replyToID: UUID?
    let chartVersionID: UUID?
    init(id: UUID, body: String, setlistID: UUID?, replyToID: UUID?, chartVersionID: UUID? = nil) {
        self.id = id; self.body = body; self.setlistID = setlistID; self.replyToID = replyToID; self.chartVersionID = chartVersionID
    }
}

/// Only explicit retry replays a saved action; a command never changes its payload.
struct TeamChatAction: Identifiable, Codable, Equatable {
    let id: UUID
    let name: String
    let label: String
    let teamID: UUID
    let roomID: UUID?
    let payload: [String: TeamJSON]
}

private enum TeamPublicationError: Error { case changedIntent, changedCreation }

/// Original bytes and every mutation command are frozen before the first network request.
private struct TeamPublication: Codable {
    let id: UUID
    let key: String
    let kind: String
    let title: String
    let ownerID: UUID
    let churchID: UUID
    let teamID: UUID
    let request: TeamJSON
    let createCommand: UUID
    let stageCommand: UUID
    let finishCommand: UUID
    let createPayload: [String: TeamJSON]?
    let finishPayload: [String: TeamJSON]
    var targetID: UUID?
    var asset: TeamJSON?
    var completed = false
}

/// Tokens remain on this device; server/account/church/team vaults never share local state.
@MainActor final class TeamWorkspace: ObservableObject {
    @Published private(set) var session: RemoteSession?
    @Published private(set) var memberships: [TeamJSON] = []
    @Published private(set) var songs: [TeamRow] = []
    @Published private(set) var versions: [TeamRow] = []
    @Published private(set) var setlists: [TeamRow] = []
    @Published private(set) var items: [TeamRow] = []
    @Published private(set) var pendingPublications: [TeamRow] = []
    @Published private(set) var reader: MusicStand?
    @Published private(set) var live: LiveState?
    @Published private(set) var displayedCall: LiveCall?
    @Published private(set) var snapshot: TeamJSON = .null
    @Published private(set) var lease: TeamJSON = .null
    @Published private(set) var online = false
    @Published private(set) var busy = false
    @Published private(set) var message = String(localized: "팀 연결 준비 중")
    @Published var error: String?
    @Published var showConflicts = false
    @Published private(set) var conflicts: [PersonalConflict] = []
    @Published private(set) var selectedChurch: UUID?
    @Published private(set) var selectedTeam: UUID?
    @Published private(set) var cache: MusicStand?
    @Published private(set) var chatMembers: [TeamJSON] = []
    @Published private(set) var chatMessages: [TeamRow] = []
    @Published private(set) var chatDrafts: [TeamChatDraft] = []
    @Published private(set) var chatComposer = ""
    @Published private(set) var chatSetlistID: UUID?
    @Published private(set) var chatSending = false
    @Published private(set) var chatError: String?
    @Published private(set) var chatActions: [TeamChatAction] = []
    @Published private(set) var chatRooms: [TeamJSON] = []
    @Published private(set) var chatReports: [TeamRow] = []
    @Published private(set) var chatBlockedAuthors: Set<UUID> = []
    @Published private(set) var chatComposerReplyID: UUID?
    @Published private(set) var chatComposerChartID: UUID?
    @Published private(set) var chatRoomsHaveMore = false
    @Published private(set) var chatReportsHaveMore = false
    @Published private(set) var chatHasMore = false
    private var chatRoomGeneration = UUID()
    private var chatBlockGeneration = UUID()
    private var chatBlockRevision: Int64 = 0
    private var chatSnapshotBlockRevision: Int64 = 0
    private var chatServerBlocked: Set<UUID> = []
    private var chatPendingBlocks: [UUID: Bool] = [:]
    private var chatStateLoaded = false
    private var chatRoomsCursor: UUID?
    private var chatReportsCursor: UUID?
    private var chatRoomsFlight: UUID?
    private var chatSnapshotFlight: (generation: UUID, id: UUID)?
    private var chatReadFlight: UUID?
    private var chatReportsFlight: UUID?
    @Published private(set) var chatReadRevision: Int64 = 0
    private var chatRevision: Int64 = 0
    private var chatVisible = false
    @Published private(set) var preferredVersions: [UUID: UUID] = [:]
    private var cacheObservation: AnyCancellable?
    private var assets: [TeamRow] = []
    private var api: RemoteAPI?
    private var polling: Task<Void, Never>?
    private var catalogHintRefresh: (id: UUID, task: Task<Void, Never>)?
    private var catalogHintPending = false
    private var catalogRefreshSchedule = CatalogRefreshSchedule()
    private let hints = RealtimeHints()
    private var syncing = false
    private var context = UUID()
    private var openGeneration: UInt64 = 0
    private var publishCommand: (payload: [String: TeamJSON], callID: UUID)?
    private var refreshFlight: (id: UUID, task: Task<RemoteSession, Error>)?
    private let root: URL
    private let keychainService: String
    private(set) var deviceID: UUID
    private var sharedHeads: [String: TeamJSON] = [:]
    private var pendingPreferences: [UUID: UUID] = [:]
    private var preferenceGeneration: UInt64 = 0
    private var savingPreferences = false
    private let realtimeEnabled: Bool
    var scopeID: UUID { context }
    var configured: Bool { api != nil }
    var isAWS: Bool { api?.configuration.provider == .aws }
    var canLead: Bool {
        memberships.contains { $0["church_id"].uuid == selectedChurch && $0["team_id"].uuid == selectedTeam && ["admin", "leader"].contains($0["role"].text ?? "") }
    }
    var canAdmin: Bool { memberships.contains { $0["church_id"].uuid == selectedChurch && $0["team_id"].uuid == selectedTeam && $0["role"].text == "admin" } }
    var hasLease: Bool {
        guard lease["active"].flag, lease["device_id"].uuid == deviceID, lease["controller_user_id"].uuid == session?.userID,
              let expiry = lease["expires_at"].text, let date = Self.parseDate(expiry) else { return false }
        return date > Date()
    }
    static func parseDate(_ value: String) -> Date? {
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    var pending: LiveCall? { live?.ended == false ? live?.pending : nil }
    var currentPerformanceKey: String? { displayedCall?.performanceKey }
    var teamMismatch: Bool {
        guard let call = displayedCall, call.performanceItemID == reader?.performanceItemID else { return false }
        return call.teamChartVersionID != reader?.current?.id
    }

    init(testRoot: URL? = nil, configuration: RemoteConfiguration? = nil, transport: URLSession = .shared, realtimeEnabled: Bool = true) {
        self.realtimeEnabled = realtimeEnabled
        root = (testRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
            .appendingPathComponent("WorshipCueTeams")
        #if DEBUG
        let testNamespace = testRoot.map { ".test." + Self.hash(Data($0.path.utf8)) } ?? ""
        #else
        let testNamespace = ""
        #endif
        let deviceKey = "worshipcue.device" + testNamespace
        let stored = UserDefaults.standard.string(forKey: deviceKey)
        deviceID = stored.flatMap(UUID.init(uuidString:)) ?? UUID()
        if stored == nil { UserDefaults.standard.set(deviceID.uuidString, forKey: deviceKey) }
        let url = Bundle.main.object(forInfoDictionaryKey: "WorshipCueSupabaseURL") as? String ?? ""
        let key = Bundle.main.object(forInfoDictionaryKey: "WorshipCueSupabaseKey") as? String ?? ""
        let provider = Bundle.main.object(forInfoDictionaryKey: "WorshipCueRemoteProvider") as? String ?? "aws"
        let awsURL = Bundle.main.object(forInfoDictionaryKey: "WorshipCueAWSAPIURL") as? String ?? ""
        let socketURL = Bundle.main.object(forInfoDictionaryKey: "WorshipCueAWSWebSocketURL") as? String ?? ""
        let config = configuration ?? (provider == "aws"
            ? URL(string: awsURL).flatMap { try? RemoteConfiguration(url: $0, provider: .aws, webSocketURL: URL(string: socketURL)) }
            : URL(string: url).flatMap { try? RemoteConfiguration(url: $0, publishableKey: key) })
        if let config { api = RemoteAPI(configuration: config, transport: transport) }
        keychainService = "com.worshipcue.session." + Self.hash(Data(((config?.provider == .aws ? "aws:" : "") + (config?.url.absoluteString ?? "unconfigured")).utf8)) + testNamespace
        if configured { message = String(localized: "로그인하면 팀 악보를 연결할 수 있어요.") }
    }

    func restore() async {
        guard configured, let data = try? secureRead() else { return }
        do {
            session = try JSONDecoder().decode(RemoteSession.self, from: data)
            try loadCatalog()
            let captured = context
            await cache?.start()
            guard captured == context else { return }
            try await restoreReaderSelection()
            try await loadConflicts()
            await refresh()
        } catch { report(error) }
    }
    func sendCode(_ email: String) async -> Bool {
        await perform {
            guard let api, email.count <= 254, email.contains("@") else { throw RemoteError.configuration }
            try await api.sendOTP(email: email.trimmingCharacters(in: .whitespacesAndNewlines))
            message = String(localized: "이메일의 인증 번호를 입력해 주세요.")
        }
    }
    func signIn(_ email: String, code: String) async -> Bool {
        await perform {
            guard let api, code.count >= 6, code.count <= 10, code.allSatisfy(\.isNumber) else { throw RemoteError.configuration }
            let captured = context
            let value = try await api.verifyOTP(email: email.trimmingCharacters(in: .whitespacesAndNewlines), code: code)
            guard captured == context else { throw RemoteError.authentication }
            try secureWrite(JSONEncoder().encode(value)); session = value; context = UUID()
            try loadCatalog()
            try await fetchLibrary()
        }
    }
    func redeem(_ token: String, guest: Bool, displayName: String? = nil) async -> Bool {
        await perform {
            guard let api else { throw RemoteError.configuration }
            if guest && session == nil {
                let captured = context
                let value = try await api.guest(invitationToken: token.trimmingCharacters(in: .whitespacesAndNewlines))
                guard captured == context else { throw RemoteError.authentication }
                try secureWrite(JSONEncoder().encode(value)); session = value; context = UUID()
            }
            let captured = context, auth = try await credentials()
            var payload: [String: TeamJSON] = ["token": .string(token.trimmingCharacters(in: .whitespacesAndNewlines))]
            if let displayName {
                let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, name.count <= 120 else { throw RemoteError.configuration }
                payload["display_name"] = .string(name)
            }
            let receipt = try await api.json("functions/v1/redeem-invitation", token: auth.accessToken, body: .object(payload))
            guard captured == context else { throw RemoteError.authentication }
            try await switchContext(church: receipt.requiredID("church_id"), team: receipt.requiredID("team_id"))
            try await fetchLibrary()
        }
    }
    func createWorkspace(_ name: String, memberDisplayName: String? = nil) async -> Bool {
        await perform {
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 100 else { throw RemoteError.configuration }
            let memberName = memberDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let memberName { guard !memberName.isEmpty, memberName.count <= 120 else { throw RemoteError.configuration } }
            let command = try creationCommand("workspace", name: name, memberName: memberName)
            let receipt: TeamJSON
            if let saved = try creationReceipt("workspace") { receipt = saved }
            else {
                var payload: [String: TeamJSON] = ["command_id": .id(command), "display_name": .string(name), "timezone": try creationTimezone("workspace")]
                if let memberName { payload["member_display_name"] = .string(memberName) }
                receipt = try await rpc("create_church_and_default_team", payload)
                _ = try receipt.requiredID("church_id"); _ = try receipt.requiredID("team_id")
                try saveCreationReceipt("workspace", receipt: receipt)
            }
            try await finishWorkspaceCreation("workspace", receipt: receipt)
        }
    }
    func createTeam(_ name: String) async -> Bool {
        await perform {
            guard let church = selectedChurch else { throw RemoteError.forbidden }
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 100 else { throw RemoteError.configuration }
            let saved = try creationReceipt("team")
            guard canAdmin || saved != nil else { throw RemoteError.forbidden }
            let command = try creationCommand("team", name: name, church: church)
            let receipt: TeamJSON
            if let saved { receipt = saved }
            else {
                receipt = try await rpc("create_team", ["command_id": .id(command), "church_id": .id(church), "display_name": .string(name)])
                _ = try receipt.requiredID("team_id")
                guard receipt["church_id"].uuid == church else { throw RemoteError.invalidResponse }
                try saveCreationReceipt("team", receipt: receipt)
            }
            try await finishWorkspaceCreation("team", receipt: receipt)
        }
    }
    private func finishWorkspaceCreation(_ kind: String, receipt: TeamJSON) async throws {
        try await switchContext(church: receipt.requiredID("church_id"), team: receipt.requiredID("team_id"))
        let captured = context
        do {
            try await fetchLibrary()
            guard captured == context else { throw RemoteError.authentication }
            try finishCreation(kind)
        } catch {
            guard captured == context else { throw RemoteError.authentication }
            guard Self.isConnectivityFailure(error) else { throw error }
            online = false
            message = String(localized: "교회·팀을 만들었어요. 연결 후 같은 이름으로 다시 확인하면 중복으로 만들지 않습니다.")
        }
    }
    private func creationFile(_ kind: String) throws -> URL {
        guard let session else { throw RemoteError.authentication }
        let folder = root.appendingPathComponent(keychainService).appendingPathComponent(session.userID.uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("pending-" + kind + ".json")
    }
    private func creationCommand(_ kind: String, name: String, church: UUID? = nil, memberName: String? = nil) throws -> UUID {
        let file = try creationFile(kind), scope = church.map(TeamJSON.id) ?? .null
        if FileManager.default.fileExists(atPath: file.path) {
            let prior = try JSONDecoder().decode(TeamJSON.self, from: Data(contentsOf: file))
            guard prior["display_name"].text == name, prior["church_id"] == scope,
                  prior["member_display_name"].text == memberName else { throw TeamPublicationError.changedCreation }
            return try prior.requiredID("command_id")
        }
        let id = UUID(), value = TeamJSON.object(["display_name": .string(name), "church_id": scope,
            "member_display_name": memberName.map(TeamJSON.string) ?? .null, "timezone": .string(TimeZone.current.identifier), "command_id": .id(id)])
        try JSONEncoder().encode(value).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return id
    }
    private func creationReceipt(_ kind: String) throws -> TeamJSON? {
        let file = try creationFile(kind)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let receipt = try JSONDecoder().decode(TeamJSON.self, from: Data(contentsOf: file))["receipt"]
        if receipt == .null { return nil }
        _ = try receipt.requiredID("church_id"); _ = try receipt.requiredID("team_id")
        return receipt
    }
    private func saveCreationReceipt(_ kind: String, receipt: TeamJSON) throws {
        let file = try creationFile(kind)
        guard case .object(var value) = try JSONDecoder().decode(TeamJSON.self, from: Data(contentsOf: file)) else { throw RemoteError.invalidResponse }
        value["receipt"] = receipt
        try JSONEncoder().encode(TeamJSON.object(value)).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    private func creationTimezone(_ kind: String) throws -> TeamJSON {
        let value = try JSONDecoder().decode(TeamJSON.self, from: Data(contentsOf: creationFile(kind)))["timezone"]
        return value.text == nil ? .string(TimeZone.current.identifier) : value
    }
    private func finishCreation(_ kind: String) throws { try FileManager.default.removeItem(at: creationFile(kind)) }
    func chooseWorkspace(_ membership: TeamJSON) async {
        _ = await perform {
            try await switchContext(church: membership.requiredID("church_id"), team: membership.requiredID("team_id"))
            try await fetchLibrary()
        }
    }
    private func switchContext(church: UUID, team: UUID) async throws {
        if selectedChurch == church, selectedTeam == team { return }
        let prior = context
        try await reader?.flush(); try await cache?.flush()
        guard prior == context else { throw RemoteError.authentication }
        try saveReaderSelection()
        context = UUID(); openGeneration &+= 1; polling?.cancel(); polling = nil; clearCatalogRefresh(); await hints.disconnect()
        refreshFlight?.task.cancel(); refreshFlight = nil
        cacheObservation?.cancel(); cacheObservation = nil
        reader = nil; cache = nil; live = nil; displayedCall = nil; snapshot = .null; lease = .null
        conflicts = []; sharedHeads = [:]; publishCommand = nil; pendingPublications = []; clearChatContext()
        preferredVersions = [:]; pendingPreferences = [:]; preferenceGeneration &+= 1
        songs = []; versions = []; assets = []; setlists = []; items = []
        selectedChurch = church; selectedTeam = team; online = false
        try loadPartitionCatalog()
    }
    func logout() async -> Bool {
        await perform {
            try await reader?.flush()
            try saveReaderSelection(active: false)
            let signedOut = session, revoke = online
            try secureDelete(); polling?.cancel(); polling = nil; context = UUID(); openGeneration &+= 1; clearCatalogRefresh()
            refreshFlight?.task.cancel(); refreshFlight = nil
            await hints.disconnect(); clearChatContext(); conflicts = []; pendingPublications = []; cacheObservation?.cancel(); cacheObservation = nil;
            session = nil; reader = nil; cache = nil; live = nil; displayedCall = nil; snapshot = .null; lease = .null
            songs = []; versions = []; setlists = []; items = []; assets = []; memberships = []
            selectedChurch = nil; selectedTeam = nil; online = false
            preferredVersions = [:]; pendingPreferences = [:]; sharedHeads = [:]; publishCommand = nil; preferenceGeneration &+= 1
            message = String(localized: "로그아웃했어요. 이 계정의 메모는 기기에 보관됩니다.")
            if revoke, let api, let signedOut { try? await api.signOut(token: signedOut.accessToken, refreshToken: signedOut.refreshToken) }
        }
    }
    private func credentials() async throws -> RemoteSession {
        guard let api, var value = session else { throw RemoteError.authentication }
        let captured = context, user = value.userID
        if value.expiresAt.timeIntervalSinceNow < 60 {
            let flight: (id: UUID, task: Task<RemoteSession, Error>)
            if let running = refreshFlight { flight = running }
            else { let original = value; flight = (UUID(), Task { try await api.refresh(original) }); refreshFlight = flight }
            defer { if refreshFlight?.id == flight.id { refreshFlight = nil } }
            value = try await flight.task.value
            guard context == captured, session?.userID == user else { throw RemoteError.authentication }
            try secureWrite(JSONEncoder().encode(value)); session = value
            // A ticket is bound to the old managed token's lifetime; obtain a fresh one on the next subscription check.
            await hints.disconnect()
            guard context == captured, session?.userID == user else { throw RemoteError.authentication }
        }
        return value
    }
    func accountRPC(_ name: String, _ payload: [String: TeamJSON] = [:]) async throws -> TeamJSON {
        guard let api else { throw RemoteError.configuration }
        guard session?.anonymous == false else { throw RemoteError.forbidden }
        let captured = context, owner = session?.userID, auth = try await credentials()
        guard captured == context, owner == auth.userID, !auth.anonymous else { throw RemoteError.authentication }
        let value = try await api.rpc(name, token: auth.accessToken, payload)
        guard captured == context, session?.userID == owner else { throw RemoteError.authentication }
        return value
    }
    func rpc(_ name: String, _ payload: [String: TeamJSON]) async throws -> TeamJSON {
        guard let api else { throw RemoteError.configuration }
        let captured = context, auth = try await credentials()
        guard captured == context else { throw RemoteError.authentication }
        var scoped = payload
        if let selectedTeam, name != "create_church_and_default_team" {
            scoped["selected_team_id"] = .id(selectedTeam)
            if scoped["team_id"] == nil { scoped["team_id"] = .id(selectedTeam) }
        }
        let result = try await api.rpc(name, token: auth.accessToken, scoped)
        guard captured == context else { throw RemoteError.authentication }
        return result
    }
    func refresh(maintainSubscription: Bool = true) async {
        guard configured, session != nil else { return }
        _ = await perform { try await fetchLibrary(maintainSubscription: maintainSubscription); try await syncPreferences(); try await reconcile(); await refreshChat() }
    }
    private func belongsToSelectedTeam(_ value: TeamJSON) -> Bool {
        guard let church = selectedChurch, let team = selectedTeam else { return false }
        return value["church_id"].uuid == church && value["team_id"].uuid == team
    }
    private func validatedCatalog(songs songValues: [TeamJSON], versions versionValues: [TeamJSON], assets assetValues: [TeamJSON],
                                  setlists setlistValues: [TeamJSON], items itemValues: [TeamJSON], preferences preferenceValues: [TeamJSON],
                                  user: UUID) throws -> (songs: [TeamRow], versions: [TeamRow], assets: [TeamRow], setlists: [TeamRow], items: [TeamRow], preferences: [UUID: UUID]) {
        let strict = api?.configuration.provider == .aws
        func rows(_ values: [TeamJSON]) throws -> [TeamRow] {
            if strict, !values.allSatisfy(belongsToSelectedTeam) { throw RemoteError.invalidResponse }
            let scoped = values.filter(belongsToSelectedTeam), parsed = try scoped.map(TeamRow.init)
            guard Set(parsed.map(\.id)).count == parsed.count else { throw RemoteError.invalidResponse }
            return parsed
        }
        let songs = try rows(songValues), versions = try rows(versionValues), assets = try rows(assetValues)
        let setlists = try rows(setlistValues), items = try rows(itemValues)
        let songIDs = Set(songs.map(\.id)), setlistIDs = Set(setlists.map(\.id))
        let versionMap = Dictionary(uniqueKeysWithValues: versions.map { ($0.id, $0.value) })
        let assetMap = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0.value) })
        for song in songs { _ = try song.value.requiredText("canonical_title") }
        for asset in assets {
            let hash = try asset.value.requiredText("sha256")
            guard hash.count == 64, hash.allSatisfy({ "0123456789abcdef".contains($0) }),
                  let bytes = asset.value["bytes"].integer, bytes > 0 else { throw RemoteError.invalidResponse }
            _ = try asset.value.requiredText("storage_key")
        }
        for row in versions {
            let value = row.value
            guard let song = value["song_id"].uuid, songIDs.contains(song), let asset = assetMap[try value.requiredID("pdf_asset_id")],
                  let number = value["version_number"].integer, number > 0,
                  let count = value["page_count"].integer, count > 0,
                  case .array(let pages) = value["page_manifest"], pages.count == Int(count) else { throw RemoteError.invalidResponse }
            _ = try pages.map(Self.geometry)
            if let key = value["written_key"].text { guard MusicalKey.isValid(key) else { throw RemoteError.invalidResponse } }
            if strict { guard asset["type"].text == "pdf", asset["status"].text == "verified" else { throw RemoteError.invalidResponse } }
        }
        for setlist in setlists {
            _ = try setlist.value.requiredText("title")
            guard setlist.value["revision"].integer != nil else { throw RemoteError.invalidResponse }
        }
        for row in items {
            let value = row.value
            guard let setlist = value["setlist_id"].uuid, setlistIDs.contains(setlist),
                  let song = value["song_id"].uuid, songIDs.contains(song),
                  let chart = value["team_chart_version_id"].uuid, versionMap[chart]?["song_id"].uuid == song,
                  let key = value["performance_key"].text, MusicalKey.isValid(key),
                  ["planned", "standby", "ad_hoc"].contains(value["kind"].text ?? "") else { throw RemoteError.invalidResponse }
        }
        if strict, !preferenceValues.allSatisfy({ belongsToSelectedTeam($0) && $0["user_id"].uuid == user }) { throw RemoteError.invalidResponse }
        var preferences: [UUID: UUID] = [:]
        for value in preferenceValues where belongsToSelectedTeam(value) && value["user_id"].uuid == user {
            let song = try value.requiredID("song_id"), version = try value.requiredID("preferred_version_id")
            guard songIDs.contains(song), versionMap[version]?["song_id"].uuid == song, preferences[song] == nil else { throw RemoteError.invalidResponse }
            preferences[song] = version
        }
        return (songs, versions, assets, setlists, items, preferences)
    }
    private func fetchLibrary(maintainSubscription: Bool = true) async throws {
        guard let api else { throw RemoteError.configuration }
        let auth = try await credentials(), initial = context
        let membershipValues = try await api.rows("memberships", token: auth.accessToken)
        guard initial == context else { throw RemoteError.authentication }
        memberships = membershipValues.filter { $0["user_id"].uuid == auth.userID && $0["active"].flag }
        if selectedTeam == nil, let first = memberships.first {
            try await switchContext(church: first.requiredID("church_id"), team: first.requiredID("team_id"))
        }
        guard let team = selectedTeam else { online = true; return }
        let captured = context, prefGeneration = preferenceGeneration
        let songValues, versionValues, assetValues, setlistValues, itemValues, preferenceValues: [TeamJSON]
        if api.configuration.provider == .aws {
            let catalog = try await api.teamCatalog(token: auth.accessToken, teamID: team)
            songValues = catalog["songs"].list; versionValues = catalog["chart_versions"].list
            assetValues = catalog["assets"].list; setlistValues = catalog["setlists"].list
            itemValues = catalog["performance_items"].list
            preferenceValues = auth.anonymous ? [] : catalog["personal_preferences"].list
        } else {
            songValues = try await api.rows("songs", token: auth.accessToken, teamID: team)
            versionValues = try await api.rows("chart_versions", token: auth.accessToken, teamID: team)
            assetValues = try await api.rows("assets", token: auth.accessToken, teamID: team)
            setlistValues = try await api.rows("setlists", token: auth.accessToken, teamID: team)
            itemValues = try await api.rows("performance_items", token: auth.accessToken, teamID: team)
            preferenceValues = auth.anonymous ? [] : try await api.rows("personal_preferences", token: auth.accessToken, teamID: team)
        }
        guard captured == context else { throw RemoteError.authentication }
        let catalog = try validatedCatalog(songs: songValues, versions: versionValues, assets: assetValues,
            setlists: setlistValues, items: itemValues, preferences: preferenceValues, user: auth.userID)
        // Parsing and cross-reference checks finish before any published metadata or cache is replaced.
        songs = catalog.songs; versions = catalog.versions; assets = catalog.assets; setlists = catalog.setlists; items = catalog.items
        if prefGeneration == preferenceGeneration {
            preferredVersions = catalog.preferences
            preferredVersions.merge(pendingPreferences) { _, local in local }
        }
        online = true; message = String(localized: "팀 자료 확인됨 · 페이지 이동은 기기별로")
        try ensureCache(); await cache?.start()
        guard captured == context else { throw RemoteError.authentication }
        try applyCachedPreferences(); try savePreferences(); try saveCatalog(); try loadPublications(); try await loadConflicts()
        guard captured == context else { throw RemoteError.authentication }
        catalogRefreshSchedule.refreshed()
        if maintainSubscription, api.configuration.provider == .aws { try? await subscribe(); startPolling() }
    }
    private var partition: URL? {
        guard let session, let church = selectedChurch, let team = selectedTeam else { return nil }
        // Legacy church-only vaults remain untouched; ownership is never inferred.
        return root.appendingPathComponent(keychainService).appendingPathComponent(session.userID.uuidString)
            .appendingPathComponent(church.uuidString).appendingPathComponent(team.uuidString)
    }
    func operationDirectory() throws -> URL {
        guard let partition, session?.anonymous == false else { throw RemoteError.authentication }
        try FileManager.default.createDirectory(at: partition, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        return partition
    }
    private func ensureCache() throws {
        guard let partition, let session, let church = selectedChurch else { return }
        if cache == nil {
            cacheObservation?.cancel()
            let stand = MusicStand(applicationSupport: partition, churchID: church, ownerID: session.userID, seedFixtures: false,
                preferenceNamespace: accountDefaultsKey + "." + church.uuidString + "." + (selectedTeam?.uuidString ?? "none"))
            cache = stand
            cacheObservation = stand.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        }
    }
    private func saveCatalog() throws {
        guard let partition else { return }
        try FileManager.default.createDirectory(at: partition, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(TeamJSON.object(["songs": .array(songs.map(\.value)), "versions": .array(versions.map(\.value)),
            "assets": .array(assets.map(\.value)), "setlists": .array(setlists.map(\.value)), "items": .array(items.map(\.value)),
            "memberships": .array(memberships)]))
        try data.write(to: partition.appendingPathComponent("team-catalog.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        // Only opaque IDs are stored beside the secure session; no notes/tokens/email in defaults.
        UserDefaults.standard.set(selectedChurch?.uuidString, forKey: accountDefaultsKey + ".church")
        UserDefaults.standard.set(selectedTeam?.uuidString, forKey: accountDefaultsKey + ".team")
    }
    private func loadCatalog() throws {
        selectedChurch = UserDefaults.standard.string(forKey: accountDefaultsKey + ".church").flatMap(UUID.init(uuidString:))
        selectedTeam = UserDefaults.standard.string(forKey: accountDefaultsKey + ".team").flatMap(UUID.init(uuidString:))
        try loadPartitionCatalog()
    }
    private var accountDefaultsKey: String { keychainService + "." + (session?.userID.uuidString ?? "signed-out") }
    private func loadPartitionCatalog() throws {
        guard let partition, FileManager.default.fileExists(atPath: partition.appendingPathComponent("team-catalog.json").path) else { return }
        let json = try JSONDecoder().decode(TeamJSON.self, from: Data(contentsOf: partition.appendingPathComponent("team-catalog.json")))
        guard let user = session?.userID else { throw RemoteError.authentication }
        let catalog = try validatedCatalog(songs: json["songs"].list, versions: json["versions"].list, assets: json["assets"].list,
            setlists: json["setlists"].list, items: json["items"].list, preferences: [], user: user)
        songs = catalog.songs; versions = catalog.versions; assets = catalog.assets; setlists = catalog.setlists; items = catalog.items
        memberships = json["memberships"].list.filter { $0["user_id"].uuid == session?.userID && $0["active"].flag }
        try ensureCache()
        try loadPreferences()
        try loadPublications()
        let uncertain = partition.appendingPathComponent("uncertain-call.json")
        if FileManager.default.fileExists(atPath: uncertain.path),
           case .object(let payload) = try JSONDecoder().decode(TeamJSON.self, from: Data(contentsOf: uncertain)),
           let command = payload["command_id"]?.uuid { publishCommand = (payload, command) }
        message = String(localized: "저장된 팀 자료 · 최신 안내는 연결 후 확인")
    }
    private func preferenceRows(_ values: [UUID: UUID]) -> [TeamJSON] {
        values.sorted { $0.key.uuidString < $1.key.uuidString }.map { .object(["song_id": .id($0.key), "preferred_version_id": .id($0.value)]) }
    }
    private func savePreferences() throws {
        guard let partition else { throw RemoteError.authentication }
        try FileManager.default.createDirectory(at: partition, withIntermediateDirectories: true)
        let value = TeamJSON.object(["preferred": .array(preferenceRows(preferredVersions)), "pending": .array(preferenceRows(pendingPreferences))])
        try JSONEncoder().encode(value).write(to: partition.appendingPathComponent("preferences.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    private func loadPreferences() throws {
        guard let partition else { return }
        let file = partition.appendingPathComponent("preferences.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let value = try JSONDecoder().decode(TeamJSON.self, from: Data(contentsOf: file))
        func map(_ rows: [TeamJSON]) throws -> [UUID: UUID] {
            var result: [UUID: UUID] = [:]
            for row in rows { result[try row.requiredID("song_id")] = try row.requiredID("preferred_version_id") }
            return result
        }
        preferredVersions = try map(value["preferred"].list); pendingPreferences = try map(value["pending"].list)
        preferredVersions.merge(pendingPreferences) { _, local in local }
    }
    private func applyCachedPreferences() throws {
        guard let cache else { return }
        for (song, id) in preferredVersions {
            if let version = cache.library.versions.first(where: { $0.id == id && $0.songID == song }), cache.library.preferences[song] != id {
                guard cache.prefer(version) else { throw RemoteError.invalidResponse }
            }
        }
    }
    private func syncPreferences() async throws {
        guard online, session?.anonymous == false, !savingPreferences else { return }
        savingPreferences = true; defer { savingPreferences = false }
        let captured = context
        for (song, version) in pendingPreferences.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            _ = try await rpc("set_personal_preference", ["song_id": .id(song), "preferred_version_id": .id(version)])
            guard captured == context else { return }
            if pendingPreferences[song] == version { pendingPreferences.removeValue(forKey: song); preferenceGeneration &+= 1; try savePreferences() }
        }
    }
    private static func callJSON(_ call: LiveCall) -> TeamJSON {
        .object(["id": .id(call.id), "session_id": .id(call.sessionID), "sequence": .int(call.sequence),
            "performance_item_id": .id(call.performanceItemID), "song_id": .id(call.songID),
            "team_chart_version_id": .id(call.teamChartVersionID), "performance_key": .string(call.performanceKey)])
    }
    private func saveReaderSelection(active: Bool? = nil) throws {
        guard let partition else { return }
        try FileManager.default.createDirectory(at: partition, withIntermediateDirectories: true)
        let value = TeamJSON.object(["team_reader": .bool(active ?? (reader != nil)), "snapshot": snapshot,
            "displayed_call": displayedCall.map(Self.callJSON) ?? .null, "chart_version_id": cache?.current.map { .id($0.id) } ?? .null,
            "page_index": .int(Int64(cache?.pageIndex ?? 0))])
        try JSONEncoder().encode(value).write(to: partition.appendingPathComponent("reader-selection.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    private func restoreReaderSelection() async throws {
        guard let partition, let cache else { return }
        let captured = context
        let file = partition.appendingPathComponent("reader-selection.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let value = try JSONDecoder().decode(TeamJSON.self, from: Data(contentsOf: file))
        if let id = value["snapshot"]["id"].uuid {
            live = LiveState(sessionID: id); try applySnapshot(value["snapshot"], persist: false)
            live?.setConnectivity(.offline); online = false
        }
        guard let chartID = value["chart_version_id"].uuid, cache.verifyVersion(chartID) != nil, let page = value["page_index"].integer else { return }
        if cache.current?.id != chartID || cache.pageIndex != Int(page) {
            guard await cache.openVersion(chartID, page: Int(page), validateIntent: { self.context == captured }) else { throw RemoteError.invalidResponse }
        }
        guard captured == context, let version = cache.currentLibraryVersion else { throw RemoteError.authentication }
        if value["team_reader"].flag { reader = cache }
        if value["displayed_call"] != .null {
            let call = try value["displayed_call"].call()
            guard call.songID == version.songID, call.sessionID == live?.sessionID else { return }
            let chart = try Chart(id: version.id, songID: version.songID, writtenKey: version.writtenKey, pageCount: cache.pageCount)
            live?.navigate(to: try DisplayedChart(chart: chart, pageIndex: cache.pageIndex, performanceItemID: call.performanceItemID,
                acknowledgedCallID: call.id, acknowledgedPerformanceKey: call.performanceKey))
            displayedCall = call; cache.setPerformanceItem(call.performanceItemID)
            if let cached = try cachedTeamDrawing(item: call.performanceItemID, chart: version.id, page: cache.pageIndex) {
                let exact = try LayerIdentity(churchID: cache.church, versionID: version.id, pageIndex: cache.pageIndex, scope: .team(performanceItemID: call.performanceItemID))
                guard let page = cache.pdfView.document?.page(at: cache.pageIndex) else { throw RemoteError.invalidResponse }
                cache.applyShared(exact, geometry: try page.canonicalGeometry(), drawing: cached.0)
            }
        }
    }
    func songTitle(_ id: UUID) -> String { songs.first { $0.id == id }?.value["canonical_title"].text ?? String(localized: "곡 정보 확인 필요") }
    func versionsForSong(_ id: UUID) -> [TeamRow] { versions.filter { $0.value["song_id"].uuid == id }.sorted { ($0.value["version_number"].integer ?? 0) > ($1.value["version_number"].integer ?? 0) } }
    static func geometry(_ json: TeamJSON) throws -> PageGeometry {
        func number(_ camel: String, _ snake: String) throws -> Double {
            let v = json[camel] == .null ? json[snake] : json[camel]
            guard case .number(let number) = v, number.isFinite else { throw RemoteError.invalidResponse }; return number
        }
        return try PageGeometry(cropX: number("cropX", "crop_x"), cropY: number("cropY", "crop_y"),
            cropWidth: number("cropWidth", "crop_width"), cropHeight: number("cropHeight", "crop_height"), rotation: Int(number("rotation", "rotation")))
    }
    static func jsonGeometry(_ value: PageGeometry) throws -> TeamJSON { try JSONDecoder().decode(TeamJSON.self, from: JSONEncoder().encode(value)) }
    private func downloadVersion(_ id: UUID) async throws -> MusicStand {
        let captured = context
        try ensureCache(); guard let cache else { throw RemoteError.invalidResponse }
        await cache.start()
        guard captured == context else { throw RemoteError.authentication }
        if cache.charts.contains(where: { $0.id == id }), cache.verifyVersion(id) != nil { return cache }
        guard let version = versions.first(where: { $0.id == id })?.value,
              let songID = version["song_id"].uuid, let song = songs.first(where: { $0.id == songID }),
              let asset = assets.first(where: { $0.id == version["pdf_asset_id"].uuid })?.value,
              let bytes = asset["bytes"].integer, let number = version["version_number"].integer,
              let api else { throw RemoteError.invalidResponse }
        let auth = try await credentials()
        let data = try await api.download(key: asset.requiredText("storage_key"), token: auth.accessToken, maximumBytes: 100 * 1024 * 1024)
        guard captured == context else { throw RemoteError.authentication }
        let receipt = LibraryVersion(id: id, songID: songID, number: Int(number), assetID: id,
            label: try version.requiredText("label"), writtenKey: version["written_key"].text)
        try cache.cachePublished(data, song: LibrarySong(id: songID, title: try song.value.requiredText("canonical_title")), version: receipt,
            sha256: asset.requiredText("sha256"), bytes: Int(bytes), pages: version["page_manifest"].list.map(Self.geometry))
        try applyCachedPreferences()
        return cache
    }
    func preparedVersion(_ id: UUID) async throws -> MusicStand { try await downloadVersion(id) }
    func preserveTeamCopies(draft: Data, remote: Data) throws {
        guard let partition else { throw RemoteError.authentication }
        let value = TeamJSON.object(["draft": .string(draft.base64EncodedString()), "remote": .string(remote.base64EncodedString())])
        try JSONEncoder().encode(value).write(to: partition.appendingPathComponent("team-copies-\(UUID()).json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func openVersion(_ id: UUID, page: Int? = nil) async -> Bool {
        await perform {
            let captured = context
            openGeneration &+= 1; let generation = openGeneration
            let cache = try await downloadVersion(id)
            try await restorePersonalForOpen(cache, versionID: id)
            guard await cache.openVersion(id, page: page, validateIntent: { self.context == captured && self.openGeneration == generation }) else { throw RemoteError.invalidResponse }
            reader = cache; openGeneration &+= 1
            navigationChanged()
            try saveReaderSelection()
            try await refreshSharedForOpen()
        }
    }
    private func restorePersonalForOpen(_ cache: MusicStand, versionID: UUID) async throws {
        let captured = context
        do { try await restorePersonal(cache, versionID: versionID) }
        catch {
            guard captured == context, Self.isConnectivityFailure(error), cache.verifyVersion(versionID) != nil else { throw error }
            online = false; live?.setConnectivity(.offline)
        }
    }
    private func refreshSharedForOpen() async throws {
        let captured = context
        do { try await refreshShared() }
        catch {
            guard captured == context, Self.isConnectivityFailure(error) else { throw error }
            online = false; live?.setConnectivity(.offline)
        }
    }
    func useLocalReader() async -> Bool {
        await perform { try await reader?.flush(); reader = nil; openGeneration &+= 1; try saveReaderSelection(active: false) }
    }
    func prepare(_ setlist: TeamRow) async -> Bool {
        await perform {
            let captured = context
            try await fetchLibrary()
            let manifest = try await rpc("preflight_manifest", ["setlist_id": .id(setlist.id)])
            let ids = manifest["charts"].list.compactMap { $0["id"].uuid }
            guard !ids.isEmpty else { throw RemoteError.invalidResponse }
            for id in ids {
                let prepared = try await downloadVersion(id)
                try await restorePersonal(prepared, versionID: id)
            }
            for head in manifest["annotation_heads"].list {
                let item = try head.requiredID("performance_item_id"), chart = try head.requiredID("chart_version_id")
                guard let page = head["page_index"].integer, ids.contains(chart) else { throw RemoteError.invalidResponse }
                let archive = try await verifiedTeamArchive(head, expectedContext: captured)
                guard captured == context else { throw RemoteError.authentication }
                _ = try saveSharedSnapshot(head, archive: archive, item: item, chart: chart, page: Int(page))
            }
            let final = try await rpc("preflight_manifest", ["setlist_id": .id(setlist.id)])
            guard final == manifest else { throw RemoteError.conflict }
            guard captured == context, let partition else { throw RemoteError.authentication }
            try JSONEncoder().encode(manifest).write(to: partition.appendingPathComponent("prepared-setlist-\(setlist.id).json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            message = String(localized: "팀 악보와 현재 팀 메모 다운로드·검증 완료")
        }
    }
    func invite(role: String, setlistID: UUID?) async -> String? {
        var token: String?
        _ = await perform {
            guard let church = selectedChurch, let team = selectedTeam else { throw RemoteError.invalidResponse }
            let expiry = ISO8601DateFormatter().string(from: Date().addingTimeInterval(7 * 86400))
            let receipt = try await rpc("create_invitation", ["church_id": .id(church), "team_id": .id(team),
                "permitted_role": .string(role), "setlist_id": setlistID.map(TeamJSON.id) ?? .null,
                "expires_at": .string(expiry), "max_uses": .int(1)])
            token = try receipt.requiredText("token")
        }
        return token
    }
    func revokeInvite(_ id: UUID) async -> Bool { await perform { _ = try await rpc("revoke_invitation", ["invitation_id": .id(id)]) } }
    private func uploadAsset(_ data: Data, type: String, expectedContext: UUID? = nil, commandID: UUID? = nil) async throws -> TeamJSON {
        let captured = context
        guard expectedContext == nil || expectedContext == captured else { throw RemoteError.authentication }
        guard let church = selectedChurch, let api else { throw RemoteError.invalidResponse }
        let hash = Self.hash(data), count = Int64(data.count)
        var staging: [String: TeamJSON] = ["church_id": .id(church), "type": .string(type), "sha256": .string(hash), "expected_bytes": .int(count)]
        if let commandID { staging["command_id"] = .id(commandID) }
        let receipt = try await rpc("stage_asset", staging)
        if commandID != nil {
            _ = try receipt.requiredID("id")
            guard receipt["church_id"].uuid == church, receipt["sha256"].text == hash,
                  receipt["bytes"].integer == count else { throw RemoteError.invalidResponse }
            if api.configuration.provider == .aws {
                let parts = try receipt.requiredText("storage_key").split(separator: "/")
                guard belongsToSelectedTeam(receipt), receipt["type"].text == type, parts.count == 3,
                      UUID(uuidString: String(parts[0])) == selectedTeam,
                      UUID(uuidString: String(parts[1])) == session?.userID else { throw RemoteError.invalidResponse }
            }
        }
        let auth = try await credentials()
        guard captured == context else { throw RemoteError.authentication }
        let mime = type == "pdf" ? "application/pdf" : (type == "preview" ? "image/png" : "application/octet-stream")
        do { try await api.upload(key: receipt.requiredText("storage_key"), bytes: data, type: mime, token: auth.accessToken) }
        catch {
            // Immutable PUT or an already-verified asset can outlive a lost response. Finalization must prove the same authorized hash/bytes.
            guard commandID != nil else { throw error }
            switch error {
            case RemoteError.conflict, RemoteError.forbidden, RemoteError.server("HTTP_412"): break
            default: throw error
            }
        }
        guard captured == context else { throw RemoteError.authentication }
        let finalized = try await api.json("functions/v1/finalize-asset", token: auth.accessToken, body: .object([
            "asset_id": .id(try receipt.requiredID("id")), "sha256": .string(hash), "expected_bytes": .int(count)]))
        guard captured == context else { throw RemoteError.authentication }
        if commandID != nil {
            guard finalized["id"] == receipt["id"], finalized["sha256"].text == hash,
                  finalized["bytes"].integer == count else { throw RemoteError.invalidResponse }
            if api.configuration.provider == .aws {
                guard belongsToSelectedTeam(finalized), finalized["status"].text == "verified", finalized["type"].text == type else { throw RemoteError.invalidResponse }
            }
            if type == "pdf" {
                guard !finalized["page_manifest"].list.isEmpty else { throw RemoteError.invalidResponse }
                _ = try finalized["page_manifest"].list.map(Self.geometry)
            }
        }
        return finalized
    }
    private func publicationFolder() throws -> URL {
        let folder = try operationDirectory().appendingPathComponent("pending-publications")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        return folder
    }
    private func publicationURL(_ key: String) throws -> URL {
        try publicationFolder().appendingPathComponent(Self.hash(Data(key.utf8)) + ".json")
    }
    private func validatePublication(_ intent: TeamPublication) throws {
        guard session?.anonymous == false, intent.ownerID == session?.userID,
              intent.teamID == selectedTeam, intent.churchID == selectedChurch else { throw RemoteError.authentication }
    }
    private func readPublication(_ file: URL) throws -> TeamPublication {
        let value = try JSONDecoder().decode(TeamPublication.self, from: Data(contentsOf: file))
        try validatePublication(value); return value
    }
    private func writePublication(_ intent: TeamPublication) throws {
        try validatePublication(intent)
        try JSONEncoder().encode(intent).write(to: publicationURL(intent.key), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try loadPublications()
    }
    private func loadPublications() throws {
        guard session?.anonymous == false, partition != nil else { pendingPublications = []; return }
        let folder = try publicationFolder()
        pendingPublications = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { file in
                let intent = try readPublication(file)
                return try TeamRow(.object(["id": .id(intent.id), "key": .string(intent.key), "title": .string(intent.title),
                    "kind": .string(intent.kind), "completed": .bool(intent.completed)]))
            }
    }
    private func freezePublication(key: String, kind: String, title: String, request: TeamJSON,
                                   create: [String: TeamJSON]?, finish: [String: TeamJSON], target: UUID?, pdf: Data? = nil) throws -> TeamPublication {
        guard canLead, let church = selectedChurch, let team = selectedTeam, let owner = session?.userID else { throw RemoteError.forbidden }
        let file = try publicationURL(key)
        if FileManager.default.fileExists(atPath: file.path) {
            let saved = try readPublication(file)
            guard saved.request == request else { throw TeamPublicationError.changedIntent }
            return saved
        }
        let intent = TeamPublication(id: UUID(), key: key, kind: kind, title: title, ownerID: owner, churchID: church, teamID: team,
            request: request, createCommand: UUID(), stageCommand: UUID(), finishCommand: UUID(), createPayload: create,
            finishPayload: finish, targetID: target)
        if let pdf {
            try pdf.write(to: try publicationFolder().appendingPathComponent(intent.id.uuidString + ".pdf"),
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        try writePublication(intent)
        return intent
    }
    private func continuePublication(_ saved: TeamPublication) async throws {
        var intent = saved
        try validatePublication(intent)
        guard intent.completed || canLead else { throw RemoteError.forbidden }
        let captured = context
        if !intent.completed {
            if intent.targetID == nil, var create = intent.createPayload {
                create["command_id"] = .id(intent.createCommand)
                let created = try await rpc(intent.kind == "pdf" ? "create_song" : "create_setlist", create)
                guard captured == context else { throw RemoteError.authentication }
                let target = try created.requiredID("id")
                guard created["church_id"].uuid == intent.churchID,
                      api?.configuration.provider != .aws || created["team_id"].uuid == intent.teamID else { throw RemoteError.invalidResponse }
                intent.targetID = target; try writePublication(intent)
            }
            guard let target = intent.targetID else { throw RemoteError.invalidResponse }
            var finish = intent.finishPayload
            finish["command_id"] = .id(intent.finishCommand)
            if intent.kind == "pdf" {
                if intent.asset == nil {
                    let data = try Data(contentsOf: try publicationFolder().appendingPathComponent(intent.id.uuidString + ".pdf"))
                    guard Self.hash(data) == intent.request["sha256"].text,
                          Int64(data.count) == intent.request["bytes"].integer else { throw RemoteError.invalidResponse }
                    intent.asset = try await uploadAsset(data, type: "pdf", expectedContext: captured, commandID: intent.stageCommand)
                    guard captured == context else { throw RemoteError.authentication }; try writePublication(intent)
                }
                guard let asset = intent.asset else { throw RemoteError.invalidResponse }
                finish["song_id"] = .id(target); finish["verified_pdf_asset_id"] = .id(try asset.requiredID("id"))
                finish["page_manifest"] = asset["page_manifest"]
            } else { finish["setlist_id"] = .id(target) }
            let receipt = try await rpc(intent.kind == "pdf" ? "publish_chart_version" : "save_setlist", finish)
            guard captured == context else { throw RemoteError.authentication }
            if intent.kind == "pdf" {
                _ = try receipt.requiredID("id")
                guard receipt["song_id"].uuid == target, receipt["pdf_asset_id"] == finish["verified_pdf_asset_id"],
                      receipt["page_manifest"] == finish["page_manifest"], receipt["church_id"].uuid == intent.churchID,
                      api?.configuration.provider != .aws || receipt["team_id"].uuid == intent.teamID else { throw RemoteError.invalidResponse }
            } else {
                guard receipt["id"].uuid == target, let revision = receipt["revision"].integer,
                      revision > (finish["base_revision"]?.integer ?? 0),
                      api?.configuration.provider != .aws || receipt["team_id"].uuid == intent.teamID else { throw RemoteError.invalidResponse }
            }
            intent.completed = true; try writePublication(intent)
        }
        // A lost catalog refresh must not turn an acknowledged publication into a second mutation.
        do {
            try await fetchLibrary()
            guard captured == context else { throw RemoteError.authentication }
            try removePublication(intent)
            message = String(localized: "팀 게시를 완료했어요. 기기의 원본과 개인 메모는 그대로 보관됩니다.")
        } catch {
            guard captured == context else { throw RemoteError.authentication }
            if intent.completed, Self.isConnectivityFailure(error) {
                online = false
                message = String(localized: "서버에 게시했어요. 목록 확인은 연결 후 직접 다시 시도해 주세요.")
            } else { throw error }
        }
    }
    private func removePublication(_ intent: TeamPublication) throws {
        try validatePublication(intent)
        try FileManager.default.removeItem(at: publicationURL(intent.key))
        if intent.kind == "pdf" { try? FileManager.default.removeItem(at: try publicationFolder().appendingPathComponent(intent.id.uuidString + ".pdf")) }
        try loadPublications()
    }
    func retryPublication(_ row: TeamRow) async -> Bool {
        await perform {
            guard let key = row.value["key"].text else { throw RemoteError.invalidResponse }
            let intent = try readPublication(publicationURL(key))
            guard intent.id == row.id else { throw RemoteError.invalidResponse }
            try await continuePublication(intent)
        }
    }
    func discardPublication(_ row: TeamRow) async -> Bool {
        await perform {
            guard let key = row.value["key"].text else { throw RemoteError.invalidResponse }
            let intent = try readPublication(publicationURL(key))
            guard intent.id == row.id else { throw RemoteError.invalidResponse }
            try removePublication(intent)
        }
    }
    func publish(_ local: MusicStand, versionID: UUID, songID: UUID?) async -> Bool {
        await perform {
            guard let church = selectedChurch, let team = selectedTeam,
                  let version = local.library.versions.first(where: { $0.id == versionID }),
                  let localSong = local.library.songs.first(where: { $0.id == version.songID }) else { throw RemoteError.invalidResponse }
            let data = try local.sourceBytes(versionID)
            let request: TeamJSON = .object(["version_id": .id(versionID), "song_id": songID.map(TeamJSON.id) ?? .null,
                "title": .string(localSong.title), "label": .string(version.label), "written_key": version.writtenKey.map(TeamJSON.string) ?? .null,
                "sha256": .string(Self.hash(data)), "bytes": .int(Int64(data.count))])
            let intent = try freezePublication(key: "pdf-\(versionID)-\(songID?.uuidString ?? "new")", kind: "pdf", title: localSong.title, request: request,
                create: songID == nil ? ["church_id": .id(church), "team_id": .id(team), "canonical_title": .string(localSong.title)] : nil,
                finish: ["label": .string(version.label), "written_key": version.writtenKey.map(TeamJSON.string) ?? .null], target: songID, pdf: data)
            try await continuePublication(intent)
        }
    }
    func prefer(_ versionID: UUID) async {
        _ = await perform {
            let cache = try await downloadVersion(versionID)
            guard let version = cache.library.versions.first(where: { $0.id == versionID }), cache.prefer(version) else { throw RemoteError.invalidResponse }
            preferredVersions[version.songID] = version.id; preferenceGeneration &+= 1
            if session?.anonymous == false { pendingPreferences[version.songID] = version.id }
            try savePreferences()
            message = online ? String(localized: "내 기본 악보를 저장했어요.") : String(localized: "내 기본 악보를 기기에 저장했어요. 연결되면 계정에 저장합니다.")
            try await syncPreferences()
        }
    }
    func saveSetlist(id: UUID?, title: String, revision: Int64, entries: [TeamItemDraft]) async -> Bool {
        await perform {
            guard let church = selectedChurch, let team = selectedTeam else { throw RemoteError.invalidResponse }
            let proposed: [TeamJSON] = try entries.enumerated().map { position, item in
                guard let version = versions.first(where: { $0.id == item.versionID })?.value, MusicalKey.isValid(item.key) else { throw RemoteError.invalidResponse }
                return .object(["id": .id(item.id), "song_id": version["song_id"], "team_chart_version_id": .id(item.versionID),
                    "performance_key": .string(item.key), "position": item.standby ? .null : .int(Int64(position)), "kind": .string(item.standby ? "standby" : "planned")])
            }
            let finish: [String: TeamJSON] = ["base_revision": .int(revision), "title": .string(title), "items": .array(proposed)]
            let intent = try freezePublication(key: "setlist-\(id?.uuidString ?? "new")", kind: "setlist", title: title,
                request: .object(finish), create: id == nil ? ["church_id": .id(church), "team_id": .id(team), "title": .string(title),
                    "timezone": .string(TimeZone.current.identifier)] : nil, finish: finish, target: id)
            try await continuePublication(intent)
        }
    }
    func publishSetlist(_ local: LocalSetlist, mapping: [UUID: UUID]) async -> Bool {
        await perform {
            guard let church = selectedChurch, let team = selectedTeam else { throw RemoteError.invalidResponse }
            let proposed: [TeamJSON] = try local.items.enumerated().map { position, item in
                guard let versionID = mapping[item.versionID], let version = versions.first(where: { $0.id == versionID })?.value,
                      let song = version["song_id"].uuid, let key = item.performanceKey ?? version["written_key"].text, MusicalKey.isValid(key)
                else { throw RemoteError.invalidResponse }
                return .object(["id": .id(item.id), "song_id": .id(song), "team_chart_version_id": .id(versionID),
                    "performance_key": .string(key), "position": item.section == .planned ? .int(Int64(position)) : .null, "kind": .string(item.section.rawValue)])
            }
            let create: [String: TeamJSON] = ["church_id": .id(church), "team_id": .id(team), "title": .string(local.title),
                "timezone": .string(local.timeZoneID), "service_time": .string(ISO8601DateFormatter().string(from: local.serviceDate))]
            let request = TeamJSON.object(["create": .object(create), "items": .array(proposed)])
            // Cloud item identities are generated once and retained with this frozen publication.
            let cloudItems: [TeamJSON] = proposed.map { item in guard case .object(var fields) = item else { return .null }; fields["id"] = .id(UUID()); return .object(fields) }
            let intent = try freezePublication(key: "local-setlist-\(local.id)", kind: "setlist", title: local.title, request: request,
                create: create, finish: ["base_revision": .int(0), "items": .array(cloudItems)], target: nil)
            try await continuePublication(intent)
        }
    }
    func joinSession(_ id: UUID) async -> Bool {
        await perform {
            let value = try await rpc("get_session_snapshot", ["session_id": .id(id)])
            live = LiveState(sessionID: id); snapshot = value
            try applySnapshot(value)
            try await subscribe()
            startPolling()
        }
    }
    func sessions() async -> [TeamRow] {
        do { guard let api else { return [] }; let auth = try await credentials()
            let captured = context
            let values = try await api.rows("live_sessions", token: auth.accessToken, teamID: selectedTeam)
            guard captured == context, session?.userID == auth.userID else { return [] }
            return try values.filter(belongsToSelectedTeam).map(TeamRow.init)
        } catch { report(error); return [] }
    }
    func acquire(_ setlistID: UUID, takeover: Bool) async -> Bool {
        await perform {
            guard let api else { throw RemoteError.configuration }
            let auth = try await credentials(), captured = context
            let leases = try await api.rows("editor_leases", token: auth.accessToken, teamID: selectedTeam)
            guard captured == context else { throw RemoteError.authentication }
            let current = leases.first { $0["setlist_id"].uuid == setlistID }
            lease = try await rpc("acquire_editor", ["setlist_id": .id(setlistID), "device_id": .id(deviceID),
                "expected_epoch": .int(current?["epoch"].integer ?? 0), "explicit_takeover": .bool(takeover)])
        }
    }
    func startSession(_ setlistID: UUID) async -> Bool {
        await perform {
            guard let epoch = lease["epoch"].integer else { throw RemoteError.conflict }
            let value = try await rpc("start_session", ["setlist_id": .id(setlistID), "command_id": .id(UUID()), "device_id": .id(deviceID), "epoch": .int(epoch)])
            let id = try value.requiredID("id")
            live = LiveState(sessionID: id); snapshot = value; try applySnapshot(value); try await subscribe(); startPolling()
        }
    }
    func announcePrepared(itemID: UUID?, versionID: UUID, key: String) async -> Bool {
        if let itemID, let item = items.first(where: { $0.id == itemID }) { return await announce(item, key: key) }
        guard let version = versions.first(where: { $0.id == versionID }) else { return false }
        let previous = publishCommand?.payload
        let same = previous?["session_id"]?.uuid == live?.sessionID && previous?["song_id"]?.uuid == version.value["song_id"].uuid && previous?["team_chart_version_id"]?.uuid == versionID && previous?["performance_key"]?.text == key
        let id = same ? ((previous?["ad_hoc_draft"] ?? .null)["id"].uuid ?? UUID()) : UUID()
        guard let item = try? TeamRow(.object(["id": .id(id), "song_id": version.value["song_id"], "team_chart_version_id": .id(versionID), "kind": .string("ad_hoc")])) else { return false }
        return await announce(item, key: key)
    }
    func announce(_ item: TeamRow, key: String) async -> Bool {
        await perform {
            guard online, let live, !live.ended, let epoch = lease["epoch"].integer, MusicalKey.isValid(key),
                  let song = item.value["song_id"].uuid, let version = item.value["team_chart_version_id"].uuid else { throw RemoteError.conflict }
            var payload: [String: TeamJSON] = ["session_id": .id(live.sessionID), "device_id": .id(deviceID),
                "command_id": .id(UUID()), "expected_controller_epoch": .int(epoch),
                "expected_latest_sequence": .int(snapshot["latest_sequence"].integer ?? 0), "performance_item_id": .id(item.id),
                "song_id": .id(song), "team_chart_version_id": .id(version), "performance_key": .string(key)]
            if item.value["kind"].text == "ad_hoc" { payload["ad_hoc_draft"] = .object(["id": .id(item.id)]) }
            if let previous = publishCommand, previous.payload["performance_item_id"]?.uuid == item.id,
               previous.payload["session_id"]?.uuid == live.sessionID,
               previous.payload["song_id"]?.uuid == song,
               previous.payload["team_chart_version_id"]?.uuid == version,
               previous.payload["performance_key"]?.text == key { payload = previous.payload }
            publishCommand = (payload, payload["command_id"]!.uuid!)
            if let partition { try JSONEncoder().encode(TeamJSON.object(payload)).write(to: partition.appendingPathComponent("uncertain-call.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
            _ = try await rpc("publish_call", payload)
            publishCommand = nil
            if let partition { try? FileManager.default.removeItem(at: partition.appendingPathComponent("uncertain-call.json")) }
            try await reconcile()
        }
    }
    func endSession() async -> Bool {
        await perform {
            guard let live, let epoch = lease["epoch"].integer else { throw RemoteError.conflict }
            let value = try await rpc("end_session", ["session_id": .id(live.sessionID), "command_id": .id(UUID()), "device_id": .id(deviceID), "epoch": .int(epoch)])
            try applySnapshot(value)
            if api?.configuration.provider == .aws {
                try? await subscribe(reconcileAfter: false); startPolling()
            } else {
                polling?.cancel(); polling = nil; clearCatalogRefresh(); await hints.disconnect()
            }
        }
    }
    private func applySnapshot(_ value: TeamJSON, persist: Bool = true) throws {
        guard let live, belongsToSelectedTeam(value), try value.requiredID("id") == live.sessionID else { throw RemoteError.invalidResponse }
        guard (value["latest_sequence"].integer ?? 0) >= (live.latest?.sequence ?? 0) else { return }
        guard (value["state_revision"].integer ?? 0) >= (snapshot["state_revision"].integer ?? 0),
              !live.ended || value["status"].text == "ENDED" else { return }
        // Session events update pending/history only, never reader, page, preference or preview.
        for call in value["history"].list.sorted(by: { ($0["sequence"].integer ?? 0) < ($1["sequence"].integer ?? 0) }) { _ = try self.live?.receive(call.call()) }
        if value["latest_call"] != .null { _ = try self.live?.receive(value["latest_call"].call()) }
        if value["status"].text == "ENDED" { self.live?.endSession() }
        self.live?.setConnectivity(.online); snapshot = value; online = true
        if persist { try saveReaderSelection() }
    }
    func reconcile() async throws {
        guard let live else { return }
        let captured = context, id = live.sessionID
        let value = try await rpc("get_session_snapshot", ["session_id": .id(id)])
        guard captured == context, self.live?.sessionID == id else { return }
        try applySnapshot(value)
        if let call = self.live?.latest, !versions.contains(where: { $0.id == call.teamChartVersionID }) || !songs.contains(where: { $0.id == call.songID }) {
            try await fetchLibrary()
        }
        try await refreshShared()
    }
    func accept(_ call: LiveCall, explicitVersion: UUID? = nil) async -> Bool {
        await perform {
            guard var state = live, state.pending?.id == call.id else { throw RemoteError.conflict }
            let desired = explicitVersion ?? preferredVersions[call.songID] ?? cache?.library.preferences[call.songID] ?? call.teamChartVersionID
            guard let remote = versions.first(where: { $0.id == desired }), remote.value["song_id"].uuid == call.songID,
                  let count = remote.value["page_count"].integer else { throw RemoteError.invalidResponse }
            let chart = try Chart(id: desired, songID: call.songID, writtenKey: remote.value["written_key"].text, pageCount: Int(count))
            if let reader, let current = reader.currentLibraryVersion {
                let displayed = try Chart(id: current.id, songID: current.songID, writtenKey: current.writtenKey, pageCount: reader.pageCount)
                state.navigate(to: try DisplayedChart(chart: displayed, pageIndex: reader.pageIndex))
            }
            let intent = try state.beginOpen(renderedCallID: call.id, renderedSequence: call.sequence, selectedChart: chart)
            live = state; openGeneration &+= 1
            let generation = openGeneration, captured = context
            let target = try await downloadVersion(desired)
            guard generation == openGeneration, captured == context, self.live?.latest?.id == call.id else { throw RemoteError.conflict }
            if online {
                do { try await reconcile() }
                catch {
                    guard captured == context, generation == openGeneration, Self.isConnectivityFailure(error) else { throw error }
                    online = false; self.live?.setConnectivity(.offline)
                }
            }
            guard self.live?.latest?.id == call.id else { throw RemoteError.conflict }
            var completed = self.live
            try completed?.completeOpen(intent, chart: chart, fileVerified: true)
            let page = completed?.displayed?.pageIndex ?? 0
            try await restorePersonalForOpen(target, versionID: desired)
            guard await target.openVersion(desired, page: page, validateIntent: {
                guard self.context == captured, self.openGeneration == generation else { return false }
                var current = self.live
                do { try current?.completeOpen(intent, chart: chart, fileVerified: true); return current != nil }
                catch { return false }
            }) else { throw RemoteError.invalidResponse }
            try self.live?.completeOpen(intent, chart: chart, fileVerified: true)
            target.setPerformanceItem(call.performanceItemID); reader = target; displayedCall = call
            try saveReaderSelection()
            if online {
                _ = try? await rpc("acknowledge_open", ["session_id": .id(call.sessionID), "call_id": .id(call.id), "device_id": .id(deviceID), "selected_chart_version_id": .id(desired)])
                try await refreshSharedForOpen()
            }
            else if let drawing = try cachedTeamDrawing(item: call.performanceItemID, chart: desired, page: page) {
                let identity = try LayerIdentity(churchID: target.church, versionID: desired, pageIndex: page, scope: .team(performanceItemID: call.performanceItemID))
                guard let pdfPage = target.pdfView.document?.page(at: page) else { throw RemoteError.invalidResponse }
                target.applyShared(identity, geometry: try pdfPage.canonicalGeometry(), drawing: drawing.0)
            }
        }
    }
    func navigationChanged() {
        openGeneration &+= 1
        guard let reader, let version = reader.currentLibraryVersion else { return }
        do {
            let chart = try Chart(id: version.id, songID: version.songID, writtenKey: version.writtenKey, pageCount: reader.pageCount)
            if live?.displayed?.chart.id == chart.id {
                try live?.turnPage(to: reader.pageIndex)
                reader.setPerformanceItem(live?.displayed?.performanceItemID)
            }
            else if let call = displayedCall, call.songID == chart.songID {
                live?.navigate(to: try DisplayedChart(chart: chart, pageIndex: reader.pageIndex, performanceItemID: call.performanceItemID,
                    acknowledgedCallID: call.id, acknowledgedPerformanceKey: call.performanceKey))
                reader.setPerformanceItem(call.performanceItemID)
            } else { live?.navigate(to: try DisplayedChart(chart: chart, pageIndex: reader.pageIndex)); reader.setPerformanceItem(nil); displayedCall = nil }
            try saveReaderSelection()
        } catch { report(error) }
    }
    private func subscribe(reconcileAfter: Bool = true) async throws {
        guard let api, let team = selectedTeam else { return }
        let auth = try await credentials(), captured = context
        if realtimeEnabled {
            try? await hints.connect(api: api, token: auth.accessToken, teamID: team, sessionID: live?.ended == false ? live?.sessionID : nil) { [weak self] in
                await self?.hintReceived(captured)
            }
        }
        if reconcileAfter { try await reconcile() }
    }
    func hintReceived(_ captured: UUID) async {
        guard captured == context else { return }
        if api?.configuration.provider == .aws {
            catalogHintPending = true; scheduleCatalogHintRefresh()
            return
        }
        do { try await reconcile(); await refreshChat() } catch { if captured == context { report(error) } }
    }
    private func scheduleCatalogHintRefresh() {
        guard !busy, catalogHintPending, catalogHintRefresh == nil, selectedTeam != nil else { return }
        let captured = context, id = UUID()
        catalogHintRefresh = (id, Task { [weak self] in
            guard let self else { return }
            defer { if catalogHintRefresh?.id == id { catalogHintRefresh = nil } }
            while catalogHintPending, captured == context, !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(Int.random(in: 100...400))) } catch { return }
                guard captured == context, !Task.isCancelled else { return }
                guard !busy else { return }
                catalogHintPending = false
                await refresh(maintainSubscription: false)
            }
        })
    }
    private func clearCatalogRefresh() {
        catalogHintRefresh?.task.cancel(); catalogHintRefresh = nil; catalogHintPending = false
        catalogRefreshSchedule.reset()
    }
    private func startPolling() {
        guard polling == nil else { return }
        let captured = context
        polling = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                guard let self, captured == self.context else { return }
                do {
                    if live?.ended != true, let setlist = lease["setlist_id"].uuid, let epoch = lease["epoch"].integer {
                        do { lease = try await rpc("renew_editor", ["setlist_id": .id(setlist), "device_id": .id(deviceID), "epoch": .int(epoch)]) }
                        catch RemoteError.conflict { lease = .null }
                        catch RemoteError.forbidden { lease = .null }
                        catch { if captured == context { online = false } }
                    }
                    try? await subscribe(reconcileAfter: false)
                    guard captured == context else { return }
                    if api?.configuration.provider == .aws, catalogRefreshSchedule.isDue(), !busy {
                        await refresh(maintainSubscription: false)
                    } else {
                        try await reconcile()
                        try await syncPreferences()
                        await refreshChat()
                    }
                    await syncPersonal()
                } catch { if captured == context { report(error) } }
            }
        }
    }
    func suspend() { polling?.cancel(); polling = nil; clearCatalogRefresh(); Task { await hints.disconnect() }; live?.setConnectivity(.stale); online = false }
    func resume() async { await refresh(); await syncPersonal(); if selectedTeam != nil { try? await subscribe(); startPolling() } }
    private func layer(_ chart: UUID, page: Int, item: UUID? = nil) throws -> [String: TeamJSON] {
        guard let church = selectedChurch, let team = selectedTeam, let session else { throw RemoteError.authentication }
        return ["team_id": .id(team), "church_id": .id(church), "chart_version_id": .id(chart), "page_index": .int(Int64(page)),
            "scope": .string(item == nil ? "personal" : "team"), "owner_user_id": item == nil ? .id(session.userID) : .null,
            "performance_item_id": item.map(TeamJSON.id) ?? .null]
    }
    private func assetData(_ id: UUID, maximum: Int) async throws -> Data {
        guard let api else { throw RemoteError.configuration }
        let captured = context, auth = try await credentials()
        let current = try await api.rows("assets", token: auth.accessToken, teamID: selectedTeam)
        guard captured == context else { throw RemoteError.authentication }
        guard let asset = current.first(where: { $0["id"].uuid == id && belongsToSelectedTeam($0) }), let bytes = asset["bytes"].integer else { throw RemoteError.invalidResponse }
        let data = try await api.download(key: asset.requiredText("storage_key"), token: auth.accessToken, maximumBytes: maximum)
        guard captured == context else { throw RemoteError.authentication }
        guard data.count == bytes, Self.hash(data) == asset["sha256"].text else { throw VaultError.checksum }; return data
    }
    func refreshShared() async throws {
        guard let reader, let item = reader.performanceItemID, let chart = reader.current?.id else { return }
        let page = reader.pageIndex, captured = context
        let (drawing, _) = try await loadTeamDrawing(item: item, chart: chart, page: page)
        guard captured == context, reader.current?.id == chart, reader.pageIndex == page, reader.performanceItemID == item else { return }
        guard let pdfPage = reader.pdfView.document?.page(at: page) else { throw RemoteError.invalidResponse }
        let exact = try LayerIdentity(churchID: reader.church, versionID: chart, pageIndex: page, scope: .team(performanceItemID: item))
        reader.applyShared(exact, geometry: try pdfPage.canonicalGeometry(), drawing: drawing)
    }
    func syncPersonal() async {
        guard !syncing, session?.anonymous == false, online, let cache, let store = cache.personalStore else { return }
        syncing = true; defer { syncing = false }
        let captured = context
        do {
            try await cache.flush()
            while true {
                guard captured == context else { return }
                let jobs = try await store.pendingUploads()
                guard let job = jobs.first(where: { candidate in versions.contains(where: { $0.id == candidate.snapshot.address.versionID }) && !conflicts.contains(where: { $0.local.address == candidate.snapshot.address }) }) else { break }
                guard job.snapshot.address.ownerID == session?.userID, job.snapshot.address.churchID == selectedChurch else { throw RemoteError.forbidden }
                guard versions.contains(where: { $0.id == job.snapshot.address.versionID }) else { throw RemoteError.invalidResponse }
                try await store.freezeUpload(job.commandID)
                let payload: [String: TeamJSON]
                if let saved = job.payload {
                    guard case .object(let value) = try JSONDecoder().decode(TeamJSON.self, from: saved) else { throw RemoteError.invalidResponse }; payload = value
                } else {
                    let native = try await uploadAsset(job.snapshot.archive, type: "native", expectedContext: captured)
                    let drawing = try PKDrawing(data: job.snapshot.archive)
                    let rect = CGRect(x: 0, y: 0, width: job.snapshot.geometry.width, height: job.snapshot.geometry.height)
                    guard let png = drawing.image(from: rect, scale: min(1, 1024 / max(rect.width, rect.height))).pngData() else { throw RemoteError.invalidResponse }
                    let preview = try await uploadAsset(png, type: "preview", expectedContext: captured)
                    guard captured == context else { return }
                    payload = ["layer_identity": .object(try layer(job.snapshot.address.versionID, page: job.snapshot.address.pageIndex)),
                        "command_id": .id(job.commandID), "parent_revision": job.parentRevision.map(TeamJSON.int) ?? .int(0),
                        "native_asset_id": .id(try native.requiredID("id")), "preview_asset_id": .id(try preview.requiredID("id")),
                        "geometry": try Self.jsonGeometry(job.snapshot.geometry), "device_id": .id(deviceID)]
                    try await store.attachPayload(JSONEncoder().encode(TeamJSON.object(payload)), command: job.commandID)
                }
                guard captured == context else { return }
                let receipt: TeamJSON
                do { receipt = try await rpc("save_annotation_revision", payload) }
                catch RemoteError.conflict { try await captureConflict(job, store: store, expectedContext: captured); throw RemoteError.conflict }
                guard captured == context else { return }
                guard let revision = receipt["revision_number"].integer else { throw RemoteError.invalidResponse }
                try await store.acknowledgeUpload(job.commandID, revision: revision)
            }
            let remaining = try await store.pendingUploads()
            guard captured == context else { return }
            if remaining.isEmpty { message = String(localized: "개인 메모 동기화 확인됨") }
            else if !conflicts.isEmpty { message = String(localized: "개인 메모 충돌 확인 필요 · 기기의 메모 유지됨") }
            else { message = String(localized: "기기에만 저장된 악보의 메모는 이 기기에서 보관합니다.") }
        } catch { if captured == context { report(error) } }
    }
    func teamDraft(_ item: UUID, chart: UUID, page: Int) throws -> TeamJSON {
        guard let partition else { throw RemoteError.authentication }
        let url = partition.appendingPathComponent("draft-\(item)-\(chart)-\(page).json")
        if FileManager.default.fileExists(atPath: url.path) { return try JSONDecoder().decode(TeamJSON.self, from: Data(contentsOf: url)) }
        return .null
    }
    func saveTeamDraft(_ value: TeamJSON, item: UUID, chart: UUID, page: Int) throws {
        guard let partition else { throw RemoteError.authentication }
        try JSONEncoder().encode(value).write(to: partition.appendingPathComponent("draft-\(item)-\(chart)-\(page).json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    private func sharedSnapshotURL(item: UUID, chart: UUID, page: Int) throws -> URL {
        guard let partition else { throw RemoteError.authentication }
        return partition.appendingPathComponent("team-snapshot-\(item)-\(chart)-\(page).json")
    }
    private func cachedGeometry(chart: UUID, page: Int) throws -> PageGeometry {
        guard let pages = cache?.library.assets.first(where: { $0.id == chart })?.pages, pages.indices.contains(page) else { throw RemoteError.invalidResponse }
        return pages[page]
    }
    private func saveSharedSnapshot(_ head: TeamJSON, archive: Data, item: UUID, chart: UUID, page: Int) throws -> Bool {
        guard head["performance_item_id"].uuid == item, head["chart_version_id"].uuid == chart,
              head["page_index"].integer == Int64(page), belongsToSelectedTeam(head),
              let revision = head["revision_number"].integer, revision > 0,
              Self.hash(archive) == head["native_sha256"].text, head["native_bytes"].integer == Int64(archive.count),
              try Self.geometry(head["geometry"]) == cachedGeometry(chart: chart, page: page) else { throw RemoteError.invalidResponse }
        let key = "\(item)/\(chart)/\(page)"
        let previous = try cachedTeamDrawing(item: item, chart: chart, page: page)?.1
        let known = sharedHeads[key] ?? previous
        if let known, let number = known["revision_number"].integer {
            if number > revision { return false }
            if number == revision, known["native_sha256"] != head["native_sha256"] { throw RemoteError.invalidResponse }
        }
        _ = try PKDrawing(data: archive)
        try JSONEncoder().encode(TeamJSON.object(["team_id": selectedTeam.map(TeamJSON.id) ?? .null, "church_id": .id(cache!.church), "item": .id(item), "chart": .id(chart), "page": .int(Int64(page)),
            "head": head, "archive": .string(archive.base64EncodedString())])).write(
            to: sharedSnapshotURL(item: item, chart: chart, page: page), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        sharedHeads[key] = head
        return true
    }
    private func cachedTeamDrawing(item: UUID, chart: UUID, page: Int) throws -> (PKDrawing, TeamJSON)? {
        let file = try sharedSnapshotURL(item: item, chart: chart, page: page)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let value = try JSONDecoder().decode(TeamJSON.self, from: Data(contentsOf: file))
        guard belongsToSelectedTeam(value), value["item"].uuid == item, value["chart"].uuid == chart,
              value["page"].integer == Int64(page), let archive = Data(base64Encoded: try value.requiredText("archive")),
              archive.count <= LocalInkStore.maximumArchiveBytes else { throw RemoteError.invalidResponse }
        let head = value["head"]
        if head != .null {
            guard head["scope"].text == "team", head["owner_user_id"] == .null, belongsToSelectedTeam(head),
                  head["performance_item_id"].uuid == item, head["chart_version_id"].uuid == chart, head["page_index"].integer == Int64(page),
                  Self.hash(archive) == head["native_sha256"].text, head["native_bytes"].integer == Int64(archive.count),
                  let revision = head["revision_number"].integer, revision > 0,
                  try Self.geometry(head["geometry"]) == cachedGeometry(chart: chart, page: page) else { throw RemoteError.invalidResponse }
        }
        return (try PKDrawing(data: archive), head)
    }
    private func verifiedTeamArchive(_ head: TeamJSON, expectedContext: UUID) async throws -> Data {
        guard context == expectedContext, belongsToSelectedTeam(head), head["scope"].text == "team",
              head["owner_user_id"] == .null, let api, let bytes = head["native_bytes"].integer,
              bytes > 0, bytes <= LocalInkStore.maximumArchiveBytes else { throw RemoteError.invalidResponse }
        let auth = try await credentials()
        let archive = try await api.download(key: head.requiredText("native_storage_key"), token: auth.accessToken, maximumBytes: LocalInkStore.maximumArchiveBytes)
        guard context == expectedContext, archive.count == bytes, Self.hash(archive) == head["native_sha256"].text else { throw RemoteError.invalidResponse }
        _ = try PKDrawing(data: archive)
        return archive
    }
    func loadTeamDrawing(item: UUID, chart: UUID, page: Int) async throws -> (PKDrawing, TeamJSON) {
        let captured = context
        if !online {
            guard let value = try cachedTeamDrawing(item: item, chart: chart, page: page) else { throw RemoteError.unavailable }
            return value
        }
        let head = try await rpc("get_annotation_head", ["layer_identity": .object(try layer(chart, page: page, item: item))])
        if head == .null {
            if let cached = try cachedTeamDrawing(item: item, chart: chart, page: page), cached.1 != .null { return cached }
            guard captured == context, let church = selectedChurch else { throw RemoteError.authentication }
            let value = TeamJSON.object(["team_id": selectedTeam.map(TeamJSON.id) ?? .null, "church_id": .id(church), "item": .id(item), "chart": .id(chart), "page": .int(Int64(page)),
                "head": .null, "archive": .string(PKDrawing().dataRepresentation().base64EncodedString())])
            try JSONEncoder().encode(value).write(to: sharedSnapshotURL(item: item, chart: chart, page: page), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return (PKDrawing(), head)
        }
        let data = try await verifiedTeamArchive(head, expectedContext: captured)
        guard captured == context else { throw RemoteError.authentication }
        if try !saveSharedSnapshot(head, archive: data, item: item, chart: chart, page: page), let cached = try cachedTeamDrawing(item: item, chart: chart, page: page) { return cached }
        return (try PKDrawing(data: data), head)
    }
    func publishTeamDraft(_ draft: TeamJSON, item: UUID, chart: UUID, page: Int, geometry: PageGeometry) async -> Bool {
        await perform {
            let captured = context
            guard online, let epoch = lease["epoch"].integer, let data = Data(base64Encoded: try draft.requiredText("archive")) else { throw RemoteError.conflict }
            let payload: [String: TeamJSON]
            if case .object(let existing) = draft["payload"] { payload = existing }
            else {
                let native = try await uploadAsset(data, type: "native", expectedContext: captured)
                let drawing = try PKDrawing(data: data), rect = CGRect(x: 0, y: 0, width: geometry.width, height: geometry.height)
                guard let png = drawing.image(from: rect, scale: min(1, 1024 / max(rect.width, rect.height))).pngData() else { throw RemoteError.invalidResponse }
                let preview = try await uploadAsset(png, type: "preview", expectedContext: captured)
                guard captured == context else { throw RemoteError.authentication }
                payload = ["layer_identity": .object(try layer(chart, page: page, item: item)), "command_id": draft["command_id"],
                    "parent_revision": draft["parent_revision"], "native_asset_id": .id(try native.requiredID("id")),
                    "preview_asset_id": .id(try preview.requiredID("id")), "geometry": try Self.jsonGeometry(geometry),
                    "device_id": .id(deviceID), "controller_epoch_if_team": .int(epoch)]
                var saved = draft
                if case .object(var fields) = saved { fields["payload"] = .object(payload); saved = .object(fields) }
                try saveTeamDraft(saved, item: item, chart: chart, page: page)
            }
            _ = try await rpc("save_annotation_revision", payload)
            guard captured == context, let partition else { throw RemoteError.authentication }
            try FileManager.default.removeItem(at: partition.appendingPathComponent("draft-\(item)-\(chart)-\(page).json"))
            do {
                try await refreshShared()
                message = String(localized: "팀 메모 게시됨")
            } catch {
                message = String(localized: "팀 메모 게시됨 · 화면 확인은 연결 후 다시 시도해 주세요.")
            }
        }
    }
    private var chatRoomFile: String { "chat-" + (chatSetlistID?.uuidString ?? "team") + ".json" }
    private func clearChatContext() {
        chatRoomGeneration = UUID(); chatBlockGeneration = UUID()
        chatMembers = []; chatMessages = []; chatDrafts = []; chatActions = []; chatComposer = ""; chatRevision = 0
        chatSetlistID = nil; chatVisible = false; chatError = nil; chatSending = false
        chatComposerReplyID = nil; chatComposerChartID = nil; chatRooms = []; chatReports = []; chatBlockedAuthors = []
        chatServerBlocked = []; chatPendingBlocks = [:]; chatBlockRevision = 0; chatSnapshotBlockRevision = 0
        chatStateLoaded = false; chatRoomsCursor = nil; chatReportsCursor = nil; chatRoomsHaveMore = false; chatReportsHaveMore = false
        chatRoomsFlight = nil; chatSnapshotFlight = nil; chatReadFlight = nil; chatReportsFlight = nil; chatReadRevision = 0; chatHasMore = false
    }
    private func writeChat(_ value: TeamJSON, file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    private func encodedChat<T: Encodable>(_ value: T) throws -> TeamJSON {
        try JSONDecoder().decode(TeamJSON.self, from: JSONEncoder().encode(value))
    }
    private func persistChatState() throws {
        guard let partition else { throw RemoteError.authentication }
        let pending = Dictionary(uniqueKeysWithValues: chatPendingBlocks.map { ($0.key.uuidString.lowercased(), TeamJSON.bool($0.value)) })
        try writeChat(.object(["team_id": selectedTeam.map(TeamJSON.id) ?? .null, "rooms": .array(chatRooms),
            "block_revision": .int(chatBlockRevision), "blocked_author_ids": .array(chatServerBlocked.map(TeamJSON.id)),
            "pending_blocks": .object(pending)]), file: partition.appendingPathComponent("chat-state.json"))
    }
    private func loadChatState() throws {
        guard !chatStateLoaded, let partition else { return }
        let file = partition.appendingPathComponent("chat-state.json")
        if FileManager.default.fileExists(atPath: file.path) {
            let value = try JSONDecoder().decode(TeamJSON.self, from: Data(contentsOf: file))
            guard value["team_id"].uuid == selectedTeam else { throw RemoteError.forbidden }
            chatRooms = value["rooms"].list; chatBlockRevision = value["block_revision"].integer ?? 0
            chatServerBlocked = Set(value["blocked_author_ids"].list.compactMap(\.uuid))
            if case .object(let pending) = value["pending_blocks"] {
                for (key, flag) in pending { if let id = UUID(uuidString: key), case .bool(let blocked) = flag { chatPendingBlocks[id] = blocked } }
            }
            updateBlockedAuthors()
        }
        chatStateLoaded = true
    }
    private func persistChat() throws {
        guard let partition else { throw RemoteError.authentication }
        let value = TeamJSON.object(["team_id": selectedTeam.map(TeamJSON.id) ?? .null,
            "revision": .int(chatRevision), "block_revision": .int(chatSnapshotBlockRevision), "read_revision": .int(chatReadRevision),
            "messages": .array(chatMessages.map(\.value)), "composer": .string(chatComposer),
            "reply_to_id": chatComposerReplyID.map(TeamJSON.id) ?? .null, "chart_version_id": chatComposerChartID.map(TeamJSON.id) ?? .null,
            "drafts": try encodedChat(chatDrafts), "actions": try encodedChat(chatActions)])
        try writeChat(value, file: partition.appendingPathComponent(chatRoomFile))
    }
    private func updateBlockedAuthors() {
        var ids = chatServerBlocked
        for (id, blocked) in chatPendingBlocks { if blocked { ids.insert(id) } else { ids.remove(id) } }
        chatBlockedAuthors = ids
    }
    private func hiddenChatRow(_ row: TeamJSON) -> TeamJSON {
        guard chatBlockedAuthors.contains(row["author_id"].uuid ?? UUID()) || row["deleted"].flag || row["hidden"].flag,
              case .object(var fields) = row else { return row }
        fields["body"] = .string(""); fields["chart_version_id"] = .null; fields["chart_title"] = .null
        if !row["deleted"].flag { fields["hidden"] = .bool(true) }
        return .object(fields)
    }
    /// Strip all cached room bodies on this exact account/team; no retained reply quote can reveal blocked text.
    private func redactChatCaches() throws {
        chatReports = try chatReports.map { report in
            guard case .object(var fields) = report.value else { return report }
            fields["message"] = hiddenChatRow(report.value["message"]); return try TeamRow(.object(fields))
        }
        chatMessages = try chatMessages.map { try TeamRow(hiddenChatRow($0.value)) }
        guard let partition, FileManager.default.fileExists(atPath: partition.path) else { return }
        for file in try FileManager.default.contentsOfDirectory(at: partition, includingPropertiesForKeys: nil)
            where file.lastPathComponent.hasPrefix("chat-") && file.lastPathComponent != "chat-state.json" && file.pathExtension == "json" {
            let value = try JSONDecoder().decode(TeamJSON.self, from: Data(contentsOf: file))
            guard value["team_id"].uuid == selectedTeam, case .object(var fields) = value else { continue }
            fields["messages"] = .array(value["messages"].list.map(hiddenChatRow))
            try writeChat(.object(fields), file: file)
        }
    }
    private func adoptChatBlocks(_ value: TeamJSON) throws {
        guard let revision = value["block_revision"].integer else { return } // Legacy adapter has no block generation.
        guard revision >= chatBlockRevision, case .array = value["blocked_author_ids"] else { throw RemoteError.invalidResponse }
        let blocked = Set(value["blocked_author_ids"].list.compactMap(\.uuid))
        if revision != chatBlockRevision || blocked != chatServerBlocked {
            chatBlockRevision = revision; chatServerBlocked = blocked; chatBlockGeneration = UUID()
            updateBlockedAuthors(); try redactChatCaches()
        }
    }
    func updateChatComposer(_ text: String) {
        chatComposer = String(text.prefix(2000))
        do { try persistChat(); chatError = nil } catch { chatError = String(localized: "대화 초안을 저장하지 못했어요. 다시 시도해 주세요.") }
    }
    func setChatReply(_ id: UUID?) {
        chatComposerReplyID = id
        do { try persistChat() } catch { chatError = String(localized: "대화 초안을 저장하지 못했어요. 다시 시도해 주세요.") }
    }
    func setChatChart(_ id: UUID?) {
        guard id == nil || chatLinkVersions.contains(where: { $0.id == id }) else { return }
        chatComposerChartID = id
        do { try persistChat() } catch { chatError = String(localized: "대화 초안을 저장하지 못했어요. 다시 시도해 주세요.") }
    }
    func openChat(setlistID: UUID? = nil) async {
        guard session?.anonymous == false, selectedTeam != nil,
              setlistID == nil || setlists.contains(where: { $0.id == setlistID }) else { return }
        chatRoomGeneration = UUID(); let generation = chatRoomGeneration, captured = context
        chatSetlistID = setlistID; chatMessages = []; chatComposer = ""; chatDrafts = []; chatActions = []; chatRevision = 0
        chatSnapshotBlockRevision = 0; chatReadRevision = 0; chatReadFlight = nil; chatHasMore = false; chatError = nil; chatVisible = true; chatSending = false
        chatComposerReplyID = nil; chatComposerChartID = nil
        do {
            try loadChatState()
            if let partition {
                let file = partition.appendingPathComponent(chatRoomFile)
                if FileManager.default.fileExists(atPath: file.path) {
                    let value = try JSONDecoder().decode(TeamJSON.self, from: Data(contentsOf: file))
                    guard value["team_id"].uuid == selectedTeam else { throw RemoteError.forbidden }
                    chatMessages = try value["messages"].list.map { try TeamRow(hiddenChatRow($0)) }; chatRevision = value["revision"].integer ?? 0
                    chatSnapshotBlockRevision = value["block_revision"].integer ?? 0; chatReadRevision = value["read_revision"].integer ?? 0
                    chatComposer = value["composer"].text ?? ""; chatComposerReplyID = value["reply_to_id"].uuid; chatComposerChartID = value["chart_version_id"].uuid
                    if value["drafts"] != .null { chatDrafts = try JSONDecoder().decode([TeamChatDraft].self, from: JSONEncoder().encode(value["drafts"])) }
                    if value["actions"] != .null { chatActions = try JSONDecoder().decode([TeamChatAction].self, from: JSONEncoder().encode(value["actions"])) }
                    chatActions = chatActions.filter { $0.teamID == selectedTeam && $0.roomID == setlistID }
                }
            }
        } catch { chatMessages = []; chatError = String(localized: "저장된 대화를 확인하지 못했어요. 팀 자료는 그대로 보관됩니다.") }
        if let team = selectedTeam, let roster = try? await rpc("get_team_roster", ["team_id": .id(team)]),
           captured == context, generation == chatRoomGeneration { chatMembers = roster["members"].list }
        guard captured == context, generation == chatRoomGeneration else { return }
        await refreshChat()
    }
    func chatAuthorName(_ id: UUID?) -> String {
        if id == session?.userID { return String(localized: "나") }
        return chatMembers.first { $0["user_id"].uuid == id || $0["id"].uuid == id }?["display_name"].text ?? String(localized: "팀원")
    }
    func chatMessageText(_ row: TeamRow) -> String {
        if row.value["deleted"].flag { return String(localized: "삭제된 메시지") }
        if row.value["hidden"].flag || chatBlockedAuthors.contains(row.value["author_id"].uuid ?? UUID()) { return String(localized: "차단한 팀원의 메시지") }
        return row.value["body"].text ?? ""
    }
    func chatUnreadLabel(_ room: UUID?) -> String? {
        guard let value = chatRooms.first(where: { $0["setlist_id"].uuid == room }), !value["muted"].flag else { return nil }
        if let count = value["unread_count"].integer { return count > 0 ? String(min(count, 99)) + (count > 99 ? "+" : "") : nil }
        return (value["latest_revision"].integer ?? 0) > (value["read_revision"].integer ?? 0) ? String(localized: "새 대화") : nil
    }
    var chatUnreadSummary: String? {
        let active = chatRooms.filter { !$0["muted"].flag }
        let count = active.reduce(Int64(0)) { $0 + ($1["unread_count"].integer ?? 0) }
        let unknown = active.contains { $0["unread_count"] == .null && ($0["latest_revision"].integer ?? 0) > ($0["read_revision"].integer ?? 0) }
        return unknown ? String(localized: "새 대화") : (count > 0 ? String(min(count, 99)) + (count > 99 ? "+" : "") : nil)
    }
    var chatMuted: Bool { chatRooms.first { $0["setlist_id"].uuid == chatSetlistID }?["muted"].flag ?? false }
    var chatRoomScopeID: UUID { chatRoomGeneration }
    var chatSnapshotRevision: Int64 { chatRevision }
    func closeChat() { chatVisible = false; chatRoomGeneration = UUID(); chatSending = false }
    func refreshChatRooms(more: Bool = false) async {
        guard session?.anonymous == false, let team = selectedTeam, chatRoomsFlight == nil else { return }
        let captured = context, flight = UUID(), blockGeneration = chatBlockGeneration
        chatRoomsFlight = flight; defer { if chatRoomsFlight == flight { chatRoomsFlight = nil } }
        var payload: [String: TeamJSON] = ["team_id": .id(team)]
        if more, let cursor = chatRoomsCursor { payload["after_setlist_id"] = .id(cursor) }
        do {
            try loadChatState()
            let value = try await rpc("get_chat_rooms", payload)
            guard captured == context, blockGeneration == chatBlockGeneration else { return }
            guard value["team_id"].uuid == team, case .array = value["rooms"] else {
                if api?.configuration.provider == .supabase { return }; throw RemoteError.invalidResponse
            }
            try adoptChatBlocks(value)
            let rooms = value["rooms"].list
            guard rooms.allSatisfy({ row in (row["setlist_id"] == .null || row["setlist_id"].uuid != nil) && row["latest_revision"].integer != nil && row["read_revision"].integer != nil }) else { throw RemoteError.invalidResponse }
            if more {
                for row in rooms { chatRooms.removeAll { $0["setlist_id"] == row["setlist_id"] }; chatRooms.append(row) }
            } else { chatRooms = rooms }
            chatRoomsHaveMore = value["has_more"].flag; chatRoomsCursor = value["next_setlist_id"].uuid
            try persistChatState()
        } catch { if captured == context { chatError = chatFailure(error) } }
    }
    func refreshChat() async {
        await refreshChatRooms()
        guard chatVisible, session?.anonymous == false, let team = selectedTeam else { return }
        let generation = chatRoomGeneration
        guard chatSnapshotFlight?.generation != generation else { return }
        let captured = context, room = chatSetlistID, blockGeneration = chatBlockGeneration, flight = UUID()
        chatSnapshotFlight = (generation, flight)
        defer { if chatSnapshotFlight?.id == flight { chatSnapshotFlight = nil } }
        var payload: [String: TeamJSON] = ["team_id": .id(team), "after_revision": .int(chatRevision), "known_block_revision": .int(chatSnapshotBlockRevision)]
        if let room { payload["setlist_id"] = .id(room) }
        do {
            let value = try await rpc("get_chat_snapshot", payload)
            guard captured == context, generation == chatRoomGeneration, blockGeneration == chatBlockGeneration,
                  let revision = value["revision"].integer else { return }
            let reset = value["reset"].flag || value["full_reset"].flag || value["fullreset"].flag
            guard reset || revision >= chatRevision else { return }
            try adoptChatBlocks(value)
            var messages = reset ? [:] : Dictionary(uniqueKeysWithValues: chatMessages.map { ($0.id, $0) })
            for row in value["messages"].list {
                let message = try TeamRow(hiddenChatRow(row))
                guard let rowRevision = row["revision"].integer, rowRevision <= revision,
                      row["setlist_id"].uuid == room, (row["team_id"] == .null || row["team_id"].uuid == team), row["author_id"].uuid != nil,
                      row["deleted"].flag || row["hidden"].flag || row["body"].text != nil else { throw RemoteError.invalidResponse }
                if rowRevision >= (messages[message.id]?.value["revision"].integer ?? 0) { messages[message.id] = message }
            }
            chatMessages = messages.values.sorted {
                let left = $0.value["created_at"].text ?? "", right = $1.value["created_at"].text ?? ""
                return left == right ? ($0.value["created_revision"].integer ?? $0.value["revision"].integer ?? 0) < ($1.value["created_revision"].integer ?? $1.value["revision"].integer ?? 0) : left < right
            }
            chatRevision = revision; chatHasMore = value["has_more"].flag
            chatSnapshotBlockRevision = value["block_revision"].integer ?? chatSnapshotBlockRevision
            try persistChat(); try persistChatState(); chatError = nil
            // Read receipts are sent only by the view after this persisted snapshot appears.
        } catch { if captured == context, generation == chatRoomGeneration { chatError = chatFailure(error) } }
    }
    @discardableResult func markChatDisplayed(lastMessageID: UUID?, revision displayedRevision: Int64) async -> Bool {
        guard chatVisible, !chatHasMore, displayedRevision == chatRevision, lastMessageID == chatMessages.last?.id, chatRevision > chatReadRevision, chatReadFlight == nil, let team = selectedTeam else { return false }
        let captured = context, generation = chatRoomGeneration, revision = chatRevision, room = chatSetlistID, flight = UUID()
        chatReadFlight = flight; defer { if chatReadFlight == flight { chatReadFlight = nil } }
        do {
            try persistChat()
            var payload: [String: TeamJSON] = ["team_id": .id(team), "revision": .int(revision)]
            if let room { payload["setlist_id"] = .id(room) }
            _ = try await rpc("mark_chat_read", payload)
            guard captured == context, generation == chatRoomGeneration, chatVisible else { return true }
            chatReadRevision = max(chatReadRevision, revision); try persistChat()
            await refreshChatRooms()
        } catch { if captured == context, generation == chatRoomGeneration { chatError = chatFailure(error) } }
        return true
    }
    func sendChat(replyToID: UUID? = nil) async -> Bool {
        let body = chatComposer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, body.count <= 2000, !chatSending, session?.anonymous == false else { return false }
        let reply = replyToID ?? chatComposerReplyID, chart = chatComposerChartID
        guard chart == nil || chatLinkVersions.contains(where: { $0.id == chart }) else { chatError = String(localized: "이 악보 링크에 접근할 권한이 없어요."); return false }
        let draft = TeamChatDraft(id: UUID(), body: body, setlistID: chatSetlistID, replyToID: reply, chartVersionID: chart)
        chatDrafts.append(draft); chatComposer = ""; chatComposerReplyID = nil; chatComposerChartID = nil
        do { try persistChat() }
        catch { chatDrafts.removeAll { $0.id == draft.id }; chatComposer = body; chatComposerReplyID = reply; chatComposerChartID = chart; chatError = chatFailure(error); return false }
        return await retryChat(draft)
    }
    func retryChat(_ draft: TeamChatDraft) async -> Bool {
        guard !chatSending, session?.anonymous == false, let team = selectedTeam,
              chatDrafts.contains(draft), draft.setlistID == chatSetlistID else { return false }
        let captured = context, generation = chatRoomGeneration
        chatSending = true; defer { if captured == context, generation == chatRoomGeneration { chatSending = false } }
        do {
            var payload: [String: TeamJSON] = ["team_id": .id(team), "command_id": .id(draft.id), "body": .string(draft.body)]
            if let room = draft.setlistID { payload["setlist_id"] = .id(room) }
            if let reply = draft.replyToID { payload["reply_to_id"] = .id(reply) }
            if let chart = draft.chartVersionID { payload["chart_version_id"] = .id(chart) }
            _ = try await rpc("send_chat_message", payload)
            guard captured == context, generation == chatRoomGeneration else { return false }
            let pending = chatDrafts; chatDrafts.removeAll { $0.id == draft.id }
            do { try persistChat() } catch { chatDrafts = pending; throw error }
            await refreshChat(); return true
        } catch { if captured == context, generation == chatRoomGeneration { chatError = chatFailure(error) }; return false }
    }
    func discardChatDraft(_ draft: TeamChatDraft) {
        guard !chatSending else { return }
        let pending = chatDrafts; chatDrafts.removeAll { $0.id == draft.id }
        do { try persistChat() } catch { chatDrafts = pending; chatError = chatFailure(error) }
    }
    func canDeleteChat(_ row: TeamRow) -> Bool { canUseChatMessage(row) && (row.value["author_id"].uuid == session?.userID || canLead) }
    func canEditChat(_ row: TeamRow) -> Bool { session?.anonymous == false && row.value["author_id"].uuid == session?.userID && canUseChatMessage(row) }
    func canUseChatMessage(_ row: TeamRow) -> Bool { chatVisible && row.value["setlist_id"].uuid == chatSetlistID && chatMessages.contains(where: { $0.id == row.id }) && !row.value["deleted"].flag && !row.value["hidden"].flag && !chatBlockedAuthors.contains(row.value["author_id"].uuid ?? UUID()) }
    private func chatFailure(_ error: Error) -> String {
        switch error {
        case RemoteError.conflict: return String(localized: "메시지가 변경되었어요. 저장된 요청을 확인하고 새로 고친 뒤 직접 다시 선택해 주세요.")
        case RemoteError.forbidden: return String(localized: "이 대화 작업에 권한이 없어요. 저장된 요청은 유지됩니다.")
        case RemoteError.authentication: return String(localized: "로그인을 다시 확인해 주세요. 대화 초안과 요청은 기기에 유지됩니다.")
        default: return String(localized: "대화 작업을 확인하지 못했어요. 저장된 요청을 직접 다시 시도해 주세요.")
        }
    }
    @discardableResult private func queueChatAction(_ name: String, label: String, payload: [String: TeamJSON]) async -> Bool {
        guard chatVisible, !chatSending, session?.anonymous == false, let team = selectedTeam else { return false }
        if let pending = chatActions.first(where: { $0.name == name && $0.payload == payload }) { return await retryChatAction(pending) }
        if chatActions.contains(where: { $0.name == name && $0.payload["message_id"] == payload["message_id"] && $0.payload["user_id"] == payload["user_id"] && $0.payload["report_id"] == payload["report_id"] }) {
            chatError = String(localized: "이 작업의 저장된 요청을 먼저 다시 시도하거나 삭제해 주세요."); return false
        }
        let action = TeamChatAction(id: UUID(), name: name, label: label, teamID: team, roomID: chatSetlistID, payload: payload)
        chatActions.append(action)
        do { try persistChat() } catch { chatActions.removeAll { $0.id == action.id }; chatError = chatFailure(error); return false }
        return await retryChatAction(action)
    }
    func editChat(_ row: TeamRow, body: String) async -> Bool {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canEditChat(row), !text.isEmpty, text.count <= 2000, let revision = row.value["revision"].integer else { return false }
        return await queueChatAction("edit_chat_message", label: String(localized: "메시지 수정"), payload: ["message_id": .id(row.id), "expected_revision": .int(revision), "body": .string(text)])
    }
    func deleteChat(_ row: TeamRow) async -> Bool {
        guard canDeleteChat(row), let revision = row.value["revision"].integer else { return false }
        return await queueChatAction("delete_chat_message", label: String(localized: "메시지 삭제"), payload: ["message_id": .id(row.id), "expected_revision": .int(revision)])
    }
    func pinChat(_ row: TeamRow) async -> Bool {
        guard canLead, canUseChatMessage(row), let revision = row.value["revision"].integer else { return false }
        return await queueChatAction("pin_chat_message", label: String(localized: "메시지 고정 변경"), payload: ["message_id": .id(row.id), "pinned": .bool(!row.value["pinned"].flag), "expected_revision": .int(revision)])
    }
    func muteChat() async -> Bool {
        await queueChatAction("mute_chat", label: String(localized: "대화방 알림 변경"), payload: ["muted": .bool(!chatMuted)])
    }
    func reportChat(_ row: TeamRow, reason: String) async -> Bool {
        let text = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canUseChatMessage(row), !text.isEmpty, text.count <= 1000 else { return false }
        return await queueChatAction("report_chat_message", label: String(localized: "메시지 신고"), payload: ["message_id": .id(row.id), "reason": .string(text)])
    }
    func blockChatMember(_ user: UUID, blocked: Bool) async -> Bool {
        guard user != session?.userID, session?.anonymous == false, !chatSending, chatVisible else { return false }
        chatPendingBlocks[user] = blocked; chatBlockGeneration = UUID(); updateBlockedAuthors()
        do { try persistChatState(); try redactChatCaches(); try persistChat() }
        catch { chatError = chatFailure(error); return false }
        return await queueChatAction("block_chat_member", label: blocked ? String(localized: "팀원 차단") : String(localized: "팀원 차단 해제"), payload: ["user_id": .id(user), "blocked": .bool(blocked)])
    }
    func discardChatAction(_ action: TeamChatAction) {
        guard !chatSending else { return }
        let pending = chatActions; chatActions.removeAll { $0.id == action.id }
        do { try persistChat() } catch { chatActions = pending; chatError = chatFailure(error) }
        // Discarding an unconfirmed block intentionally keeps cached bodies hidden; unblock is an explicit action.
    }
    func retryChatAction(_ action: TeamChatAction) async -> Bool {
        guard chatVisible, !chatSending, session?.anonymous == false, action.teamID == selectedTeam,
              action.roomID == chatSetlistID, chatActions.contains(action) else { return false }
        if ["pin_chat_message", "resolve_chat_report"].contains(action.name), !canLead { chatError = chatFailure(RemoteError.forbidden); return false }
        if ["edit_chat_message", "delete_chat_message"].contains(action.name) {
            guard let message = chatMessages.first(where: { $0.id == action.payload["message_id"]?.uuid }),
                  message.value["author_id"].uuid == session?.userID || (action.name == "delete_chat_message" && canLead) else { chatError = chatFailure(RemoteError.forbidden); return false }
        }
        let captured = context, generation = chatRoomGeneration
        chatSending = true; defer { if captured == context, generation == chatRoomGeneration { chatSending = false } }
        do {
            var payload = action.payload; payload["team_id"] = .id(action.teamID); payload["command_id"] = .id(action.id)
            if let room = action.roomID, payload["setlist_id"] == nil { payload["setlist_id"] = .id(room) }
            let result = try await rpc(action.name, payload)
            guard captured == context, generation == chatRoomGeneration else { return false }
            if ["edit_chat_message", "delete_chat_message", "pin_chat_message"].contains(action.name) {
                guard result["id"].uuid == action.payload["message_id"]?.uuid,
                      result["team_id"] == .null || result["team_id"].uuid == action.teamID,
                      result["setlist_id"].uuid == action.roomID, let revision = result["revision"].integer else { throw RemoteError.invalidResponse }
                if let index = chatMessages.firstIndex(where: { $0.id == result["id"].uuid }),
                   revision >= (chatMessages[index].value["revision"].integer ?? 0) {
                    chatMessages[index] = try TeamRow(hiddenChatRow(result))
                }
            }
            if action.name == "block_chat_member", let user = action.payload["user_id"]?.uuid {
                if action.payload["blocked"]?.flag == true { chatServerBlocked.insert(user) } else { chatServerBlocked.remove(user); chatRevision = 0 }
                chatPendingBlocks.removeValue(forKey: user); chatBlockGeneration = UUID(); updateBlockedAuthors(); try persistChatState()
            }
            let pending = chatActions; chatActions.removeAll { $0.id == action.id }
            do { try persistChat() } catch { chatActions = pending; throw error }
            await refreshChat()
            if action.name == "resolve_chat_report" { await refreshChatReports() }
            return true
        } catch { if captured == context, generation == chatRoomGeneration { chatError = chatFailure(error) }; return false }
    }
    func refreshChatReports(more: Bool = false) async {
        guard canLead, let team = selectedTeam, chatReportsFlight == nil else { return }
        let captured = context, generation = chatRoomGeneration, blockGeneration = chatBlockGeneration, flight = UUID()
        chatReportsFlight = flight; defer { if chatReportsFlight == flight { chatReportsFlight = nil } }
        var payload: [String: TeamJSON] = ["team_id": .id(team), "status": .string("open")]
        if more, let cursor = chatReportsCursor { payload["after_report_id"] = .id(cursor) }
        do {
            let value = try await rpc("get_chat_reports", payload)
            guard captured == context, generation == chatRoomGeneration, blockGeneration == chatBlockGeneration, canLead else { return }
            guard value["team_id"].uuid == team, case .array = value["reports"] else { throw RemoteError.invalidResponse }
            let reports = try value["reports"].list.map(TeamRow.init)
            if more { for row in reports { chatReports.removeAll { $0.id == row.id }; chatReports.append(row) } } else { chatReports = reports }
            chatReportsHaveMore = value["has_more"].flag; chatReportsCursor = value["next_report_id"].uuid
        } catch { if captured == context, generation == chatRoomGeneration { chatError = chatFailure(error) } }
    }
    func chatReportMessageText(_ report: TeamRow) -> String? {
        let value = hiddenChatRow(report.value["message"])
        guard let row = try? TeamRow(value) else { return nil }
        return chatMessageText(row)
    }
    func resolveChatReport(_ report: TeamRow, dismissed: Bool) async -> Bool {
        guard canLead, let revision = report.value["revision"].integer else { return false }
        var payload: [String: TeamJSON] = ["report_id": .id(report.id), "expected_revision": .int(revision), "status": .string(dismissed ? "dismissed" : "resolved")]
        // A report can belong to another room; resolving it never navigates to that room.
        payload["setlist_id"] = report.value["setlist_id"]
        return await queueChatAction("resolve_chat_report", label: String(localized: "신고 처리"), payload: payload)
    }
    var chatLinkVersions: [TeamRow] {
        versions.filter { version in
            belongsToSelectedTeam(version.value) && version.value["published_at"].text != nil &&
            assets.contains { $0.id == version.value["pdf_asset_id"].uuid && belongsToSelectedTeam($0.value) && $0.value["type"].text == "pdf" && $0.value["status"].text == "verified" }
        }
    }
    func chatChartTitle(_ id: UUID) -> String {
        guard let version = chatLinkVersions.first(where: { $0.id == id }) else { return String(localized: "접근할 수 없는 악보") }
        let title = songs.first { $0.id == version.value["song_id"].uuid }?.value["canonical_title"].text ?? String(localized: "악보")
        return title + " · v" + String(version.value["version_number"].integer ?? 0) + (version.value["written_key"].text.map { " · " + $0 } ?? "")
    }
    func openChatChart(_ id: UUID) async -> Bool {
        guard chatVisible, chatLinkVersions.contains(where: { $0.id == id }) else { return false }
        let captured = context, intent = chatRoomGeneration
        return await perform {
            openGeneration &+= 1; let generation = openGeneration
            let stand = try await downloadVersion(id)
            try await restorePersonalForOpen(stand, versionID: id)
            guard captured == context, intent == chatRoomGeneration, chatVisible,
                  chatLinkVersions.contains(where: { $0.id == id }),
                  await stand.openVersion(id, validateIntent: { self.context == captured && self.chatRoomGeneration == intent && self.openGeneration == generation }) else { throw RemoteError.authentication }
            reader = stand; openGeneration &+= 1; navigationChanged(); try saveReaderSelection(); try await refreshSharedForOpen()
        }
    }
    func previewChatChart(_ id: UUID) async throws -> PDFDocument {
        guard chatVisible, chatLinkVersions.contains(where: { $0.id == id }) else { throw RemoteError.forbidden }
        let captured = context, generation = chatRoomGeneration
        let stand = try await downloadVersion(id)
        guard captured == context, generation == chatRoomGeneration, chatLinkVersions.contains(where: { $0.id == id }),
              let document = PDFDocument(data: try stand.sourceBytes(id)) else { throw RemoteError.invalidResponse }
        return document
    }
    @discardableResult private func perform(_ work: () async throws -> Void) async -> Bool {
        guard !busy else { return false }; busy = true; defer { busy = false; scheduleCatalogHintRefresh() }
        do { try await work(); error = nil; return true } catch { report(error); return false }
    }
    private func report(_ failure: Error) {
        switch failure {
        case TeamPublicationError.changedCreation:
            error = String(localized: "확인 대기 중인 교회·팀 만들기 요청이 있어요. 이전 이름으로 다시 시도해 주세요.")
        case TeamPublicationError.changedIntent:
            error = String(localized: "확인 대기 중인 게시 요청과 내용이 달라요. 이전 요청을 다시 확인하거나 직접 삭제한 뒤 새로 게시해 주세요.")
        case RemoteError.conflict, InkStoreError.generationConflict:
            error = String(localized: "서버 자료가 변경되었어요. 기기의 메모·초안은 유지됩니다. 두 버전을 확인한 뒤 직접 선택해 주세요.")
        case RemoteError.authentication:
            online = false; error = String(localized: "로그인을 다시 확인해 주세요. 기기의 메모는 유지됩니다.")
        case RemoteError.forbidden:
            online = false; error = String(localized: "이 팀 자료에 접근할 권한이 없어요. 관리자에게 초대를 요청해 주세요.")
        default:
            online = false; live?.setConnectivity(.offline)
            error = String(localized: "팀 연결을 확인하지 못했어요. 저장된 악보와 개인 메모는 계속 사용할 수 있습니다.")
        }
    }
    private static func isConnectivityFailure(_ error: Error) -> Bool {
        if case RemoteError.unavailable = error { return true }
        guard let network = error as? URLError else { return false }
        return [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(network.code)
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private var keychainQuery: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService, kSecAttrAccount as String: "session"] }
    private func secureRead() throws -> Data? {
        var query = keychainQuery; query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?; let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }; guard status == errSecSuccess else { throw RemoteError.authentication }; return value as? Data
    }
    private func secureWrite(_ data: Data) throws {
        let status = SecItemUpdate(keychainQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var query = keychainQuery; query[kSecValueData as String] = data; query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw RemoteError.authentication }
        } else if status != errSecSuccess { throw RemoteError.authentication }
    }
    private func secureDelete() throws { let status = SecItemDelete(keychainQuery as CFDictionary); guard status == errSecSuccess || status == errSecItemNotFound else { throw RemoteError.authentication } }
}

struct PersonalConflict: Identifiable {
    let id: UUID
    let local: InkSnapshot
    let remote: InkSnapshot
    let revision: Int64
}

extension TeamWorkspace {
    private func restorePersonal(_ cache: MusicStand, versionID: UUID) async throws {
        guard session?.anonymous == false, online, let store = cache.personalStore,
              let asset = cache.library.assets.first(where: { $0.id == versionID }), let pages = asset.pages else { return }
        let captured = context
        for (page, geometry) in pages.enumerated() {
            guard captured == context else { throw RemoteError.authentication }
            let address = try InkAddress(churchID: cache.church, ownerID: cache.owner, versionID: versionID, pageIndex: page)
            guard try await !store.hasPending(address) else { continue }
            let head = try await rpc("get_annotation_head", ["layer_identity": .object(try layer(versionID, page: page))])
            guard head != .null, let revision = head["revision_number"].integer else { continue }
            guard belongsToSelectedTeam(head), head["owner_user_id"].uuid == cache.owner,
                  head["scope"].text == "personal", head["chart_version_id"].uuid == versionID,
                  head["page_index"].integer == Int64(page) else { throw RemoteError.invalidResponse }
            let data = try await assetData(head.requiredID("native_asset_id"), maximum: 2 * 1024 * 1024)
            guard try Self.geometry(head["geometry"]) == geometry else { throw InkStoreError.geometryMismatch }
            guard captured == context else { throw RemoteError.authentication }
            _ = try PKDrawing(data: data)
            _ = try await cache.installRemotePersonal(InkSnapshot(address: address, geometry: geometry, generation: 1, archive: data),
                revision: revision, validateIntent: { self.context == captured })
        }
    }
    private func loadConflicts() async throws {
        guard let partition, let store = cache?.personalStore else { return }
        let captured = context, owner = session?.userID, church = selectedChurch
        var result: [PersonalConflict] = []
        for file in try FileManager.default.contentsOfDirectory(at: partition, includingPropertiesForKeys: nil) where file.lastPathComponent.hasPrefix("conflict-") && file.pathExtension == "json" {
            let id = file.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "conflict-", with: "")
            guard let command = UUID(uuidString: id) else { continue }
            let value = try JSONDecoder().decode(TeamJSON.self, from: Data(contentsOf: file))
            let address = try JSONDecoder().decode(InkAddress.self, from: JSONEncoder().encode(value["address"]))
            guard captured == context, address.ownerID == owner, address.churchID == church,
                  let local = try await store.load(address), let revision = value["revision"].integer,
                  let archive = Data(base64Encoded: try value.requiredText("remote_archive")) else { throw RemoteError.invalidResponse }
            guard captured == context, session?.userID == owner, selectedChurch == church else { throw RemoteError.authentication }
            _ = try PKDrawing(data: archive)
            result.append(PersonalConflict(id: command, local: local, remote: InkSnapshot(address: address,
                geometry: try Self.geometry(value["geometry"]), generation: 1, archive: archive), revision: revision))
        }
        guard captured == context, session?.userID == owner, selectedChurch == church else { throw RemoteError.authentication }
        conflicts = result
    }
    private func captureConflict(_ job: PersonalInkUpload, store: LocalInkStore, expectedContext: UUID) async throws {
        let address = job.snapshot.address
        guard expectedContext == context, address.ownerID == session?.userID, address.churchID == selectedChurch, let partition else { throw RemoteError.authentication }
        let head = try await rpc("get_annotation_head", ["layer_identity": .object(try layer(address.versionID, page: address.pageIndex))])
        guard expectedContext == context else { throw RemoteError.authentication }
        guard head != .null, let revision = head["revision_number"].integer else { throw RemoteError.conflict }
        let bytes = try await assetData(head.requiredID("native_asset_id"), maximum: 2 * 1024 * 1024)
        guard expectedContext == context else { throw RemoteError.authentication }
        let geometry = try Self.geometry(head["geometry"])
        guard geometry == job.snapshot.geometry else { throw InkStoreError.geometryMismatch }
        let remote = InkSnapshot(address: address, geometry: geometry, generation: 1, archive: bytes)
        _ = try PKDrawing(data: bytes)
        let local = try await store.load(address) ?? job.snapshot
        guard expectedContext == context, address.ownerID == session?.userID, address.churchID == selectedChurch else { throw RemoteError.authentication }
            let value: TeamJSON = .object(["address": try JSONDecoder().decode(TeamJSON.self, from: JSONEncoder().encode(address)),
                "geometry": try Self.jsonGeometry(geometry), "remote_archive": .string(bytes.base64EncodedString()), "revision": .int(revision)])
            try JSONEncoder().encode(value).write(to: partition.appendingPathComponent("conflict-\(job.commandID).json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        if !conflicts.contains(where: { $0.remote.address == address }) { conflicts.append(PersonalConflict(id: job.commandID, local: local, remote: remote, revision: revision)) }
    }
    func resolvePersonal(_ conflict: PersonalConflict, keepLocal: Bool) async -> Bool {
        await perform {
            guard let cache, let store = cache.personalStore else { throw RemoteError.invalidResponse }
            let captured = context
            guard conflict.local.address.ownerID == session?.userID, conflict.local.address.churchID == selectedChurch else { throw RemoteError.forbidden }
            try await cache.flush()
            guard captured == context else { throw RemoteError.authentication }
            let saved = try await store.resolveConflict(conflict.remote, revision: conflict.revision, keepLocal: keepLocal)
            guard captured == context else { throw RemoteError.authentication }
            try cache.refreshPersonal(saved)
            conflicts.removeAll { $0.id == conflict.id }
            if let partition { try? FileManager.default.removeItem(at: partition.appendingPathComponent("conflict-\(conflict.id).json")) }
            message = keepLocal ? String(localized: "기기의 메모를 다음 동기화에서 게시합니다. 이전 두 사본은 보관됩니다.") : String(localized: "서버 사본을 직접 선택했어요. 이전 두 사본은 보관됩니다.")
        }
    }
}
