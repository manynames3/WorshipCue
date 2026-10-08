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
}

/// Tokens remain on this device; server/account/church/team vaults never share local state.
@MainActor final class TeamWorkspace: ObservableObject {
    @Published private(set) var session: RemoteSession?
    @Published private(set) var memberships: [TeamJSON] = []
    @Published private(set) var songs: [TeamRow] = []
    @Published private(set) var versions: [TeamRow] = []
    @Published private(set) var setlists: [TeamRow] = []
    @Published private(set) var items: [TeamRow] = []
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
        let stored = UserDefaults.standard.string(forKey: "worshipcue.device")
        deviceID = stored.flatMap(UUID.init(uuidString:)) ?? UUID()
        if stored == nil { UserDefaults.standard.set(deviceID.uuidString, forKey: "worshipcue.device") }
        let url = Bundle.main.object(forInfoDictionaryKey: "WorshipCueSupabaseURL") as? String ?? ""
        let key = Bundle.main.object(forInfoDictionaryKey: "WorshipCueSupabaseKey") as? String ?? ""
        let provider = Bundle.main.object(forInfoDictionaryKey: "WorshipCueRemoteProvider") as? String ?? "aws"
        let awsURL = Bundle.main.object(forInfoDictionaryKey: "WorshipCueAWSAPIURL") as? String ?? ""
        let socketURL = Bundle.main.object(forInfoDictionaryKey: "WorshipCueAWSWebSocketURL") as? String ?? ""
        let config = configuration ?? (provider == "aws"
            ? URL(string: awsURL).flatMap { try? RemoteConfiguration(url: $0, provider: .aws, webSocketURL: URL(string: socketURL)) }
            : URL(string: url).flatMap { try? RemoteConfiguration(url: $0, publishableKey: key) })
        if let config { api = RemoteAPI(configuration: config, transport: transport) }
        keychainService = "com.worshipcue.session." + Self.hash(Data(((config?.provider == .aws ? "aws:" : "") + (config?.url.absoluteString ?? "unconfigured")).utf8))
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
    func redeem(_ token: String, guest: Bool) async -> Bool {
        await perform {
            guard let api else { throw RemoteError.configuration }
            if guest && session == nil {
                let captured = context
                let value = try await api.guest(invitationToken: token.trimmingCharacters(in: .whitespacesAndNewlines))
                guard captured == context else { throw RemoteError.authentication }
                try secureWrite(JSONEncoder().encode(value)); session = value; context = UUID()
            }
            let captured = context, auth = try await credentials()
            let receipt = try await api.json("functions/v1/redeem-invitation", token: auth.accessToken,
                body: .object(["token": .string(token.trimmingCharacters(in: .whitespacesAndNewlines))]))
            guard captured == context else { throw RemoteError.authentication }
            try await switchContext(church: receipt.requiredID("church_id"), team: receipt.requiredID("team_id"))
            try await fetchLibrary()
        }
    }
    func createWorkspace(_ name: String) async -> Bool {
        await perform {
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 100 else { throw RemoteError.configuration }
            let command = try creationCommand("workspace", name: name)
            let receipt = try await rpc("create_church_and_default_team", ["command_id": .id(command), "display_name": .string(name), "timezone": .string(TimeZone.current.identifier)])
            let church = try receipt.requiredID("church_id"), team = try receipt.requiredID("team_id")
            try finishCreation("workspace")
            try await switchContext(church: church, team: team)
            try await fetchLibrary()
        }
    }
    func createTeam(_ name: String) async -> Bool {
        await perform {
            guard canAdmin, let church = selectedChurch, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RemoteError.forbidden }
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.count <= 100 else { throw RemoteError.configuration }
            let command = try creationCommand("team", name: name, church: church)
            let receipt = try await rpc("create_team", ["command_id": .id(command), "church_id": .id(church), "display_name": .string(name)])
            let team = try receipt.requiredID("team_id")
            try finishCreation("team")
            try await switchContext(church: church, team: team)
            try await fetchLibrary()
        }
    }
    private func creationFile(_ kind: String) throws -> URL {
        guard let session else { throw RemoteError.authentication }
        let folder = root.appendingPathComponent(keychainService).appendingPathComponent(session.userID.uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("pending-" + kind + ".json")
    }
    private func creationCommand(_ kind: String, name: String, church: UUID? = nil) throws -> UUID {
        let file = try creationFile(kind), scope = church.map(TeamJSON.id) ?? .null
        if FileManager.default.fileExists(atPath: file.path) {
            let prior = try JSONDecoder().decode(TeamJSON.self, from: Data(contentsOf: file))
            if prior["display_name"].text == name, prior["church_id"] == scope { return try prior.requiredID("command_id") }
        }
        let id = UUID(), value = TeamJSON.object(["display_name": .string(name), "church_id": scope, "command_id": .id(id)])
        try JSONEncoder().encode(value).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return id
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
        conflicts = []; sharedHeads = [:]; publishCommand = nil; clearChatContext()
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
            await hints.disconnect(); clearChatContext(); conflicts = []; cacheObservation?.cancel(); cacheObservation = nil;
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
    private func rpc(_ name: String, _ payload: [String: TeamJSON]) async throws -> TeamJSON {
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
        songs = try songValues.filter(belongsToSelectedTeam).map(TeamRow.init)
        versions = try versionValues.filter(belongsToSelectedTeam).map(TeamRow.init)
        assets = try assetValues.filter(belongsToSelectedTeam).map(TeamRow.init)
        setlists = try setlistValues.filter(belongsToSelectedTeam).map(TeamRow.init)
        items = try itemValues.filter(belongsToSelectedTeam).map(TeamRow.init)
        if prefGeneration == preferenceGeneration {
            preferredVersions = [:]
            for value in preferenceValues where belongsToSelectedTeam(value) && value["user_id"].uuid == auth.userID {
                preferredVersions[try value.requiredID("song_id")] = try value.requiredID("preferred_version_id")
            }
            preferredVersions.merge(pendingPreferences) { _, local in local }
        }
        online = true; message = String(localized: "팀 자료 확인됨 · 페이지 이동은 기기별로")
        try ensureCache(); await cache?.start()
        guard captured == context else { throw RemoteError.authentication }
        try applyCachedPreferences(); try savePreferences(); try saveCatalog(); try await loadConflicts()
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
        songs = try json["songs"].list.filter(belongsToSelectedTeam).map(TeamRow.init); versions = try json["versions"].list.filter(belongsToSelectedTeam).map(TeamRow.init)
        assets = try json["assets"].list.filter(belongsToSelectedTeam).map(TeamRow.init); setlists = try json["setlists"].list.filter(belongsToSelectedTeam).map(TeamRow.init); items = try json["items"].list.filter(belongsToSelectedTeam).map(TeamRow.init)
        memberships = json["memberships"].list.filter { $0["user_id"].uuid == session?.userID && $0["active"].flag }
        try ensureCache()
        try loadPreferences()
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
            try await restorePersonal(cache, versionID: id)
            guard await cache.openVersion(id, page: page, validateIntent: { self.context == captured && self.openGeneration == generation }) else { throw RemoteError.invalidResponse }
            reader = cache; openGeneration &+= 1
            navigationChanged()
            try saveReaderSelection()
            try await refreshShared()
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
    private func uploadAsset(_ data: Data, type: String, expectedContext: UUID? = nil) async throws -> TeamJSON {
        let captured = context
        guard expectedContext == nil || expectedContext == captured else { throw RemoteError.authentication }
        guard let church = selectedChurch, let api else { throw RemoteError.invalidResponse }
        let hash = Self.hash(data), count = Int64(data.count)
        let receipt = try await rpc("stage_asset", ["church_id": .id(church), "type": .string(type), "sha256": .string(hash), "expected_bytes": .int(count)])
        let auth = try await credentials()
        guard captured == context else { throw RemoteError.authentication }
        let mime = type == "pdf" ? "application/pdf" : (type == "preview" ? "image/png" : "application/octet-stream")
        try await api.upload(key: receipt.requiredText("storage_key"), bytes: data, type: mime, token: auth.accessToken)
        guard captured == context else { throw RemoteError.authentication }
        let finalized = try await api.json("functions/v1/finalize-asset", token: auth.accessToken, body: .object([
            "asset_id": .id(try receipt.requiredID("id")), "sha256": .string(hash), "expected_bytes": .int(count)]))
        guard captured == context else { throw RemoteError.authentication }
        return finalized
    }
    func publish(_ local: MusicStand, versionID: UUID, songID: UUID?) async -> Bool {
        await perform {
            guard let church = selectedChurch, let version = local.library.versions.first(where: { $0.id == versionID }),
                  let localSong = local.library.songs.first(where: { $0.id == version.songID }) else { throw RemoteError.invalidResponse }
            let data = try local.sourceBytes(versionID)
            let target: UUID
            if let songID { target = songID }
            else {
                let created = try await rpc("create_song", ["church_id": .id(church), "command_id": .id(UUID()), "canonical_title": .string(localSong.title)])
                target = try created.requiredID("id")
            }
            let asset = try await uploadAsset(data, type: "pdf")
            _ = try await rpc("publish_chart_version", ["command_id": .id(UUID()), "song_id": .id(target),
                "verified_pdf_asset_id": .id(try asset.requiredID("id")), "label": .string(version.label),
                "written_key": version.writtenKey.map(TeamJSON.string) ?? .null, "page_manifest": asset["page_manifest"]])
            try await fetchLibrary()
            message = String(localized: "원본 PDF를 새 팀 버전으로 게시했어요. 개인 메모는 포함하지 않습니다.")
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
            let setlist: UUID
            if let id { setlist = id }
            else {
                let created = try await rpc("create_setlist", ["command_id": .id(UUID()), "church_id": .id(church), "team_id": .id(team),
                    "title": .string(title), "timezone": .string(TimeZone.current.identifier)])
                setlist = try created.requiredID("id")
            }
            var proposed: [TeamJSON] = []
            for (position, item) in entries.enumerated() {
                guard let version = versions.first(where: { $0.id == item.versionID })?.value, MusicalKey.isValid(item.key) else { throw RemoteError.invalidResponse }
                proposed.append(.object(["id": .id(item.id), "song_id": version["song_id"], "team_chart_version_id": .id(item.versionID),
                    "performance_key": .string(item.key), "position": item.standby ? .null : .int(Int64(position)), "kind": .string(item.standby ? "standby" : "planned")]))
            }
            _ = try await rpc("save_setlist", ["setlist_id": .id(setlist), "base_revision": .int(revision), "command_id": .id(UUID()), "title": .string(title), "items": .array(proposed)])
            try await fetchLibrary()
        }
    }
    func publishSetlist(_ local: LocalSetlist, mapping: [UUID: UUID]) async -> Bool {
        await perform {
            guard let church = selectedChurch, let team = selectedTeam else { throw RemoteError.invalidResponse }
            var proposed: [TeamJSON] = []
            for (position, item) in local.items.enumerated() {
                guard let versionID = mapping[item.versionID], let version = versions.first(where: { $0.id == versionID })?.value,
                      let song = version["song_id"].uuid, let key = item.performanceKey ?? version["written_key"].text, MusicalKey.isValid(key)
                else { throw RemoteError.invalidResponse }
                proposed.append(.object(["id": .id(UUID()), "song_id": .id(song), "team_chart_version_id": .id(versionID),
                    "performance_key": .string(key), "position": item.section == .planned ? .int(Int64(position)) : .null,
                    "kind": .string(item.section.rawValue)]))
            }
            let created = try await rpc("create_setlist", ["command_id": .id(UUID()), "church_id": .id(church), "team_id": .id(team),
                "title": .string(local.title), "timezone": .string(local.timeZoneID), "service_time": .string(ISO8601DateFormatter().string(from: local.serviceDate))])
            _ = try await rpc("save_setlist", ["command_id": .id(UUID()), "setlist_id": .id(try created.requiredID("id")), "base_revision": .int(0), "items": .array(proposed)])
            try await fetchLibrary()
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
            if online { try await reconcile() }
            guard self.live?.latest?.id == call.id else { throw RemoteError.conflict }
            var completed = self.live
            try completed?.completeOpen(intent, chart: chart, fileVerified: true)
            let page = completed?.displayed?.pageIndex ?? 0
            try await restorePersonal(target, versionID: desired)
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
                try await refreshShared()
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
        chatMembers = []; chatMessages = []; chatDrafts = []; chatComposer = ""; chatRevision = 0
        chatSetlistID = nil; chatVisible = false; chatError = nil; chatSending = false
    }
    private func persistChat() throws {
        guard let partition else { throw RemoteError.authentication }
        try FileManager.default.createDirectory(at: partition, withIntermediateDirectories: true)
        let drafts = try JSONDecoder().decode(TeamJSON.self, from: JSONEncoder().encode(chatDrafts))
        let value = TeamJSON.object(["team_id": selectedTeam.map(TeamJSON.id) ?? .null,
            "revision": .int(chatRevision), "messages": .array(chatMessages.map(\.value)),
            "composer": .string(chatComposer), "drafts": drafts])
        try JSONEncoder().encode(value).write(to: partition.appendingPathComponent(chatRoomFile), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func updateChatComposer(_ text: String) {
        chatComposer = String(text.prefix(2000))
        do { try persistChat(); chatError = nil }
        catch { chatError = String(localized: "대화 초안을 저장하지 못했어요. 다시 시도해 주세요.") }
    }
    func openChat(setlistID: UUID? = nil) async {
        guard session?.anonymous == false, selectedTeam != nil else { return }
        chatSetlistID = setlistID; chatMessages = []; chatComposer = ""; chatDrafts = []; chatRevision = 0; chatError = nil; chatVisible = true
        if let partition {
            let file = partition.appendingPathComponent(chatRoomFile)
            do {
                if FileManager.default.fileExists(atPath: file.path) {
                    let value = try JSONDecoder().decode(TeamJSON.self, from: Data(contentsOf: file))
                    guard value["team_id"].uuid == selectedTeam else { throw RemoteError.forbidden }
                    chatMessages = try value["messages"].list.map(TeamRow.init); chatRevision = value["revision"].integer ?? 0
                    chatComposer = value["composer"].text ?? ""
                    chatDrafts = try JSONDecoder().decode([TeamChatDraft].self, from: JSONEncoder().encode(value["drafts"]))
                }
            } catch { chatError = String(localized: "저장된 대화를 확인하지 못했어요. 팀 자료는 그대로 보관됩니다.") }
        }
        let captured = context
        if let team = selectedTeam, let roster = try? await rpc("get_team_roster", ["team_id": .id(team)]), captured == context {
            chatMembers = roster["members"].list
        }
        await refreshChat()
    }
    func chatAuthorName(_ id: UUID?) -> String {
        if id == session?.userID { return String(localized: "나") }
        return chatMembers.first { $0["user_id"].uuid == id || $0["id"].uuid == id }?["display_name"].text ?? String(localized: "팀원")
    }
    func closeChat() { chatVisible = false }
    func refreshChat() async {
        guard chatVisible, session?.anonymous == false, let team = selectedTeam else { return }
        let captured = context, room = chatSetlistID
        var payload: [String: TeamJSON] = ["team_id": .id(team), "after_revision": .int(chatRevision)]
        if let room { payload["setlist_id"] = .id(room) }
        do {
            let value = try await rpc("get_chat_snapshot", payload)
            guard captured == context, room == chatSetlistID, let revision = value["revision"].integer, revision >= chatRevision else { return }
            var messages: [UUID: TeamRow] = [:]
            for message in chatMessages { messages[message.id] = message }
            for row in value["messages"].list {
                let message = try TeamRow(row)
                guard let rowRevision = row["revision"].integer, rowRevision <= revision,
                      row["setlist_id"].uuid == room, row["author_id"].uuid != nil,
                      row["deleted"].flag || row["body"].text != nil else { throw RemoteError.invalidResponse }
                if rowRevision >= (messages[message.id]?.value["revision"].integer ?? 0) { messages[message.id] = message }
            }
            chatMessages = messages.values.sorted { ($0.value["revision"].integer ?? 0) < ($1.value["revision"].integer ?? 0) }
            chatRevision = revision; try persistChat(); chatError = nil
            _ = try await rpc("mark_chat_read", payload.merging(["revision": .int(revision)]) { _, right in right })
        } catch {
            guard captured == context, room == chatSetlistID else { return }
            chatError = String(localized: "대화 연결을 확인하지 못했어요. 초안은 기기에 저장되며 자동으로 전송하지 않습니다.")
        }
    }
    func sendChat(replyToID: UUID? = nil) async -> Bool {
        let body = chatComposer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, body.count <= 2000, !chatSending, session?.anonymous == false else { return false }
        let draft = TeamChatDraft(id: UUID(), body: body, setlistID: chatSetlistID, replyToID: replyToID)
        chatDrafts.append(draft); chatComposer = ""
        do { try persistChat() }
        catch { chatDrafts.removeAll { $0.id == draft.id }; chatComposer = body; chatError = String(localized: "대화 초안을 저장하지 못했어요. 다시 시도해 주세요."); return false }
        return await retryChat(draft)
    }
    func retryChat(_ draft: TeamChatDraft) async -> Bool {
        guard !chatSending, session?.anonymous == false, let team = selectedTeam,
              chatDrafts.contains(draft), draft.setlistID == chatSetlistID else { return false }
        let captured = context, room = chatSetlistID
        chatSending = true; defer { if captured == context { chatSending = false } }
        do {
            var payload: [String: TeamJSON] = ["team_id": .id(team), "command_id": .id(draft.id), "body": .string(draft.body)]
            if let room { payload["setlist_id"] = .id(room) }
            if let reply = draft.replyToID { payload["reply_to_id"] = .id(reply) }
            _ = try await rpc("send_chat_message", payload)
            guard captured == context, room == chatSetlistID else { return false }
            let pending = chatDrafts
            chatDrafts.removeAll { $0.id == draft.id }
            do { try persistChat() } catch { chatDrafts = pending; throw error }
            await refreshChat(); return true
        } catch {
            guard captured == context, room == chatSetlistID else { return false }
            chatError = String(localized: "전송을 확인하지 못했어요. 저장된 메시지를 직접 다시 시도해 주세요."); return false
        }
    }
    func discardChatDraft(_ draft: TeamChatDraft) {
        guard !chatSending else { return }
        let pending = chatDrafts
        chatDrafts.removeAll { $0.id == draft.id }
        do { try persistChat() } catch { chatDrafts = pending; chatError = String(localized: "대화 초안을 저장하지 못했어요. 다시 시도해 주세요.") }
    }
    @discardableResult private func perform(_ work: () async throws -> Void) async -> Bool {
        guard !busy else { return false }; busy = true; defer { busy = false; scheduleCatalogHintRefresh() }
        do { try await work(); error = nil; return true } catch { report(error); return false }
    }
    private func report(_ failure: Error) {
        switch failure {
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
