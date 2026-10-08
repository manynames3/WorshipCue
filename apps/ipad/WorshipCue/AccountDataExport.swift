import SwiftUI
import WorshipCueRemote

/// Exports only the selected team's currently authorized personal records and file references.
@MainActor final class AccountDataExport: ObservableObject {
    @Published private(set) var preflight: TeamJSON?
    @Published private(set) var exportedURL: URL?
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    private let team: TeamWorkspace
    private var generation = UUID()
    static let tables = ["memberships", "personal_preferences", "annotation_layers", "annotation_heads", "annotation_revisions", "assets", "chat_messages", "chat_preferences", "chat_blocks"]

    init(team: TeamWorkspace) { self.team = team }
    func reset() {
        generation = UUID(); preflight = nil; exportedURL = nil; busy = false; error = nil
    }
    static func validatePreflight(_ value: TeamJSON, owner: UUID) throws {
        guard value["schema_version"].integer == 1, value["owner_user_id"].uuid == owner,
              value["delete_supported"] == .bool(false), let date = value["generated_at"].text,
              TeamWorkspace.parseDate(date) != nil, value["unavailable_team_count"].integer != nil,
              case .array(let rows) = value["teams"], rows.count <= 200 else { throw RemoteError.invalidResponse }
        var seen = Set<UUID>()
        for row in rows {
            guard let id = row["team_id"].uuid, seen.insert(id).inserted, row["church_id"].uuid != nil,
                  ["member", "leader", "admin"].contains(row["role"].text ?? ""), let name = row["display_name"].text, name.count <= 120,
                  let revision = row["revision"].integer, revision >= 1,
                  case .bool = row["sole_admin"], case .bool = row["handoff_required"] else { throw RemoteError.invalidResponse }
        }
    }
    static func validatePage(_ value: TeamJSON, owner: UUID, team: UUID) throws -> Int {
        guard case .object(let object) = value, object["next_cursor"] != nil,
              value["schema_version"].integer == 1, value["owner_user_id"].uuid == owner,
              value["team_id"].uuid == team, value["export_scope"].text == "current_authorized_team" else { throw RemoteError.invalidResponse }
        let permitted = Set(tables + ["schema_version", "owner_user_id", "team_id", "export_scope", "next_cursor"])
        guard Set(object.keys).isSubset(of: permitted) else { throw RemoteError.invalidResponse }
        var count = 0
        for table in tables {
            guard case .array(let rows) = value[table] else { throw RemoteError.invalidResponse }
            count += rows.count
            for row in rows {
                guard case .object(let fields) = row, row["team_id"].uuid == team else { throw RemoteError.invalidResponse }
                let ownerKey = table == "chat_messages" ? "author_id" : ["annotation_layers", "annotation_heads", "annotation_revisions", "assets"].contains(table) ? "owner_user_id" : "user_id"
                guard row[ownerKey].uuid == owner else { throw RemoteError.invalidResponse }
                guard !fields.keys.contains(where: { ["token", "token_hash", "access_token", "refresh_token", "invitation_token", "email"].contains($0) }) else { throw RemoteError.invalidResponse }
                if ["annotation_layers", "annotation_heads", "annotation_revisions"].contains(table) { guard row["scope"].text == "personal" else { throw RemoteError.invalidResponse } }
                if table == "assets" { guard ["native", "preview"].contains(row["type"].text ?? ""), row["verified"] == .bool(true) else { throw RemoteError.invalidResponse } }
            }
        }
        guard count <= 100 else { throw RemoteError.invalidResponse }
        return count
    }
    static func validateReferences(_ records: [String: [TeamJSON]]) throws {
        var layers = Set<UUID>(), assets: [UUID: TeamJSON] = [:]
        for row in records["annotation_layers", default: []] {
            guard let id = row["id"].uuid, layers.insert(id).inserted else { throw RemoteError.invalidResponse }
        }
        for row in records["assets", default: []] {
            guard let id = row["id"].uuid, assets[id] == nil else { throw RemoteError.invalidResponse }
            assets[id] = row
        }
        for row in records["annotation_heads", default: []] + records["annotation_revisions", default: []] {
            guard let layer = row["layer_id"].uuid, layers.contains(layer) else { throw RemoteError.invalidResponse }
            for type in ["native", "preview"] {
                guard let id = row[type + "_asset_id"].uuid, let asset = assets[id], asset["type"].text == type,
                      let hash = asset["sha256"].text, hash.count == 64,
                      hash.allSatisfy({ "0123456789abcdef".contains($0) }), row[type + "_sha256"].text == hash,
                      let bytes = asset["bytes"].integer, bytes > 0, bytes <= 2 * 1024 * 1024,
                      row[type + "_bytes"].integer == bytes,
                      let key = asset["storage_key"].text, !key.isEmpty,
                      row[type + "_storage_key"].text == key else { throw RemoteError.invalidResponse }
            }
        }
    }
    static func validateCursor(_ cursor: TeamJSON, team: UUID) throws -> (UUID, String) {
        guard case .object(let fields) = cursor,
              Set(fields.keys) == Set(["schema_version", "team_id", "table", "after_key", "scope_token"]),
              cursor["schema_version"].integer == 1, cursor["team_id"].uuid == team,
              tables.contains(cursor["table"].text ?? ""), let id = cursor["after_key"].uuid,
              let scope = cursor["scope_token"].text, scope.count == 64,
              scope.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw RemoteError.invalidResponse }
        return (id, scope)
    }
    func refresh() async {
        guard !busy, let owner = team.session?.userID else { return }
        let captured = generation, scope = team.scopeID
        busy = true; error = nil
        defer { if captured == generation { busy = false } }
        do {
            let value = try await team.accountRPC("get_account_preflight")
            guard captured == generation, scope == team.scopeID else { return }
            try Self.validatePreflight(value, owner: owner)
            preflight = value
        } catch { if captured == generation, scope == team.scopeID { report(error) } }
    }
    func exportSelectedTeam() async {
        guard !busy, let owner = team.session?.userID, let selected = team.selectedTeam else { return }
        let captured = generation, scope = team.scopeID
        busy = true; error = nil; exportedURL = nil
        defer { if captured == generation { busy = false } }
        do {
            let context = try await team.accountRPC("get_account_preflight")
            guard captured == generation, scope == team.scopeID else { return }
            try Self.validatePreflight(context, owner: owner)
            guard context["teams"].list.contains(where: { $0["team_id"].uuid == selected }) else { throw RemoteError.forbidden }
            var assembled = Dictionary(uniqueKeysWithValues: Self.tables.map { ($0, [TeamJSON]()) })
            var cursor: TeamJSON?, seen = Set<UUID>(), scopeToken: String?, bytes = 0, rows = 0
            for pageNumber in 0..<1_000 {
                try Task.checkCancellation()
                var payload: [String: TeamJSON] = ["team_id": .id(selected), "selected_team_id": .id(selected), "limit": .int(100)]
                if let cursor { payload["cursor"] = cursor }
                let page = try await team.accountRPC("get_account_export_page", payload)
                guard captured == generation, scope == team.scopeID else { return }
                rows += try Self.validatePage(page, owner: owner, team: selected)
                bytes += try JSONEncoder().encode(page).count
                guard rows <= 50_000, bytes <= 64 * 1024 * 1024 else { throw RemoteError.tooLarge }
                for name in Self.tables { assembled[name, default: []].append(contentsOf: page[name].list) }
                let next = page["next_cursor"]
                if next == .null {
                    try Self.validateReferences(assembled)
                    var result = assembled.mapValues(TeamJSON.array)
                    result["schema_version"] = .int(1); result["owner_user_id"] = .id(owner); result["team_id"] = .id(selected)
                    result["export_scope"] = .string("current_authorized_team")
                    result["generated_at"] = .string(ISO8601DateFormatter().string(from: Date()))
                    result["unavailable_team_count"] = context["unavailable_team_count"]
                    result["includes_file_bytes"] = .bool(false)
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    let data = try encoder.encode(TeamJSON.object(result))
                    guard data.count <= 80 * 1024 * 1024 else { throw RemoteError.tooLarge }
                    let directory = try team.operationDirectory().appendingPathComponent("personal-data-exports")
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                        attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
                    let file = directory.appendingPathComponent("WorshipCue-Personal-Data-\(UUID().uuidString).json")
                    try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                    preflight = context; exportedURL = file
                    return
                }
                let (id, token) = try Self.validateCursor(next, team: selected)
                guard seen.insert(id).inserted, scopeToken == nil || scopeToken == token else { throw RemoteError.invalidResponse }
                scopeToken = token; cursor = next
                if pageNumber == 999 { throw RemoteError.tooLarge }
            }
        } catch { if captured == generation, scope == team.scopeID { report(error) } }
    }
    private func report(_ value: Error) {
        exportedURL = nil
        if let value = value as? RemoteError, value == .authentication || value == .forbidden {
            preflight = nil
            error = String(localized: "현재 계정과 팀 접근 권한을 다시 확인해 주세요.")
        } else { error = String(localized: "내보내기가 완료되지 않았어요. 연결을 확인한 뒤 직접 다시 시도해 주세요.") }
    }
}

struct AccountDataExportView: View {
    @ObservedObject var team: TeamWorkspace
    @StateObject private var model: AccountDataExport
    @Environment(\.dismiss) private var dismiss
    init(team: TeamWorkspace) { self.team = team; _model = StateObject(wrappedValue: AccountDataExport(team: team)) }
    var body: some View {
        NavigationStack {
            Form {
                Section("내 개인 자료") {
                    Text("현재 선택한 팀에서 접근 가능한 내 개인 기록과 필기 파일 참조를 내보냅니다. 악보·필기 파일 원본과 다른 팀원의 기록은 포함되지 않습니다.")
                    Text("읽을 수 있는 필기 사본은 악보 화면의 PDF 내보내기를 이용해 주세요.").font(.caption).foregroundStyle(.secondary)
                    Button("현재 팀의 개인 기록 내보내기") { Task { await model.exportSelectedTeam() } }
                        .disabled(model.busy || team.selectedTeam == nil)
                    if let url = model.exportedURL {
                        Label("기기에 개인 기록 파일을 저장했어요.", systemImage: "checkmark.circle")
                        ShareLink(item: url) { Label("개인 기록 파일 공유·저장", systemImage: "square.and.arrow.up") }
                    }
                    if let error = model.error { Text(error).foregroundStyle(.orange) }
                }
                if let preflight = model.preflight {
                    if let unavailable = preflight["unavailable_team_count"].integer, unavailable > 0 {
                        Section { Text("접근이 해제된 팀의 자료는 포함되지 않습니다. 기기에 남은 개인 메모가 필요하면 먼저 PDF로 내보내 주세요.") }
                    }
                    if preflight["teams"].list.contains(where: { $0["handoff_required"].flag }) {
                        Section { Text("혼자 관리하는 팀이 있어요. 팀을 떠나기 전에 다른 팀원에게 관리자 권한을 넘겨 주세요.") }
                    }
                }
                Section { Text("계정 삭제는 아직 지원하지 않습니다. 이 내보내기는 계정이나 팀 자료를 삭제하지 않습니다.").font(.caption).foregroundStyle(.secondary) }
            }.navigationTitle("개인 자료 내보내기")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } } }
                .task { await model.refresh() }
                .onChange(of: team.scopeID) { _ in model.reset(); Task { await model.refresh() } }
        }
    }
}
