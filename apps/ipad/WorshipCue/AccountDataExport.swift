import SwiftUI
import WorshipCueRemote
import CryptoKit

/// A selected-team cloud bundle, never a whole-account or unsynced-device backup.
@MainActor final class AccountDataExport: ObservableObject {
    @Published private(set) var preflight: TeamJSON?
    @Published private(set) var exportedURL: URL?
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    private let team: TeamWorkspace
    private var generation = UUID()
    private var completedDirectory: URL?
    static let tables = ["memberships", "personal_preferences", "annotation_layers", "annotation_heads", "annotation_revisions", "assets", "chat_messages", "chat_preferences", "chat_blocks"]

    init(team: TeamWorkspace) { self.team = team }
    func reset() {
        removeCompletedExport()
        generation = UUID(); preflight = nil; exportedURL = nil; busy = false; error = nil
    }
    private func removeCompletedExport() {
        if let completedDirectory { try? FileManager.default.removeItem(at: completedDirectory) }
        completedDirectory = nil; exportedURL = nil
    }
    static func rejectSecrets(_ value: TeamJSON) throws {
        switch value {
        case .object(let fields):
            for (key, value) in fields {
                guard !["token", "token_hash", "access_token", "refresh_token", "invitation_token", "email", "password", "presigned_url"].contains(key.lowercased()) else { throw RemoteError.invalidResponse }
                try rejectSecrets(value)
            }
        case .array(let rows): for row in rows { try rejectSecrets(row) }
        default: break
        }
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
            for row in rows { try validateRecord(row, table: table, owner: owner, team: team) }
        }
        guard count <= 100 else { throw RemoteError.invalidResponse }
        return count
    }
    private static func validateRecord(_ row: TeamJSON, table: String, owner: UUID, team: UUID) throws {
        guard case .object = row, row["team_id"].uuid == team else { throw RemoteError.invalidResponse }
        let ownerKey = table == "chat_messages" ? "author_id" : ["annotation_layers", "annotation_heads", "annotation_revisions", "assets"].contains(table) ? "owner_user_id" : "user_id"
        guard row[ownerKey].uuid == owner else { throw RemoteError.invalidResponse }
        try rejectSecrets(row)
        if ["annotation_layers", "annotation_heads", "annotation_revisions"].contains(table) { guard row["scope"].text == "personal" else { throw RemoteError.invalidResponse } }
        if table == "assets" { guard ["native", "preview"].contains(row["type"].text ?? ""), row["verified"] == .bool(true) else { throw RemoteError.invalidResponse } }
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
    static func verifiedBytes(_ data: Data, asset: TeamJSON) throws {
        let limit = asset["type"].text == "pdf" ? 100 * 1024 * 1024 : 2 * 1024 * 1024
        guard let count = asset["bytes"].integer, count > 0, count <= limit, data.count == count,
              asset["sha256"].text == SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() else { throw VaultError.checksum }
    }
    /// One file is downloaded, verified and written at a time; no partial archive is shareable.
    static func writeBundle(records: [String: [TeamJSON]], owner: UUID, team: UUID, unavailableTeams: TeamJSON,
                            directory: URL, chart: (UUID) async throws -> TeamJSON,
                            asset: (TeamJSON) async throws -> Data, checkContext: () throws -> Void) async throws -> URL {
        guard Set(records.keys).isSubset(of: Set(tables)), records.values.reduce(0, { $0 + $1.count }) <= 50_000 else { throw RemoteError.invalidResponse }
        for (table, rows) in records { for row in rows { try validateRecord(row, table: table, owner: owner, team: team) } }
        try validateReferences(records)
        try checkContext(); try Task.checkCancellation()
        let job = directory.appendingPathComponent("personal-export-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        let partial = job.appendingPathComponent(".archive.partial")
        let writer: AccountExportArchiveWriter
        do { writer = try AccountExportArchiveWriter(url: partial) }
        catch { try? FileManager.default.removeItem(at: job); throw error }
        do {
            var files: [TeamJSON] = [], sourceCharts: [TeamJSON] = [], sourceAssets: [UUID: TeamJSON] = [:]
            for personal in records["assets", default: []] {
                try Task.checkCancellation(); try checkContext()
                guard personal["owner_user_id"].uuid == owner, personal["team_id"].uuid == team,
                      ["native", "preview"].contains(personal["type"].text ?? ""), personal["verified"].flag else { throw RemoteError.invalidResponse }
                let id = try personal.requiredID("id"), type = try personal.requiredText("type")
                let path = "personal/" + type + "/" + id.uuidString.lowercased() + (type == "native" ? ".drawing" : ".png")
                let bytes = try await asset(personal)
                try Task.checkCancellation(); try checkContext(); try verifiedBytes(bytes, asset: personal)
                try await writer.append(name: path, data: bytes)
                files.append(.object(["asset_id": .id(id), "type": .string(type), "path": .string(path),
                    "sha256": personal["sha256"], "bytes": personal["bytes"], "purpose": .string("own_cloud_personal_ink")]))
            }
            let versions = try Set(records["annotation_layers", default: []].map { try $0.requiredID("chart_version_id") })
            for id in versions.sorted(by: { $0.uuidString < $1.uuidString }) {
                try Task.checkCancellation(); try checkContext()
                let version = try await chart(id)
                try Task.checkCancellation(); try checkContext(); try rejectSecrets(version)
                let pdf = version["pdf_asset"]
                guard version["id"].uuid == id, version["team_id"].uuid == team, pdf["team_id"].uuid == team,
                      pdf["type"].text == "pdf", pdf["verified"].flag || pdf["status"].text == "verified",
                      let pdfID = pdf["id"].uuid, version["pdf_asset_id"].uuid == pdfID,
                      version["pdf_sha256"] == pdf["sha256"], version["pdf_bytes"] == pdf["bytes"],
                      let count = version["page_count"].integer, count > 0, count <= 200,
                      version["page_manifest"].list.count == count else { throw RemoteError.invalidResponse }
                for layer in records["annotation_layers", default: []] where layer["chart_version_id"].uuid == id {
                    guard let page = layer["page_index"].integer, page >= 0, page < count else { throw RemoteError.invalidResponse }
                    for revision in records["annotation_heads", default: []] + records["annotation_revisions", default: []] where revision["layer_id"].uuid == layer["id"].uuid {
                        guard revision["geometry"] == version["page_manifest"].list[Int(page)] else { throw RemoteError.invalidResponse }
                    }
                }
                let path = "source-pdfs/" + pdfID.uuidString.lowercased() + ".pdf"
                if let previous = sourceAssets[pdfID] {
                    guard previous["sha256"] == pdf["sha256"], previous["bytes"] == pdf["bytes"] else { throw RemoteError.invalidResponse }
                } else {
                    let bytes = try await asset(pdf)
                    try Task.checkCancellation(); try checkContext(); try verifiedBytes(bytes, asset: pdf)
                    try await writer.append(name: path, data: bytes); sourceAssets[pdfID] = pdf
                    files.append(.object(["asset_id": .id(pdfID), "type": .string("pdf"), "path": .string(path),
                        "sha256": pdf["sha256"], "bytes": pdf["bytes"], "purpose": .string("authorized_source_for_own_ink")]))
                }
                let keys = ["id", "song_id", "church_id", "team_id", "version_number", "label", "written_key", "pdf_asset_id", "pdf_sha256", "pdf_bytes", "page_count", "page_manifest", "published_at", "archived_at"]
                var metadata = Dictionary(uniqueKeysWithValues: keys.map { ($0, version[$0]) })
                metadata["pdf_path"] = .string(path); sourceCharts.append(.object(metadata))
            }
            var manifest = records.mapValues(TeamJSON.array)
            manifest["schema_version"] = .int(2); manifest["owner_user_id"] = .id(owner); manifest["team_id"] = .id(team)
            manifest["export_scope"] = .string("current_authorized_team_cloud_personal_bundle")
            manifest["generated_at"] = .string(ISO8601DateFormatter().string(from: Date()))
            manifest["unavailable_team_count"] = unavailableTeams; manifest["includes_file_bytes"] = .bool(true)
            manifest["includes_local_unsynced_notes"] = .bool(false); manifest["files"] = .array(files); manifest["source_charts"] = .array(sourceCharts)
            manifest["exclusions"] = .array(["other_teams", "inaccessible_teams", "other_people_personal_records", "team_ink", "local_unsynced_notes", "local_drafts", "credentials", "automatic_restore"].map(TeamJSON.string))
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(TeamJSON.object(manifest))
            guard data.count <= 80 * 1024 * 1024 else { throw RemoteError.tooLarge }
            try await writer.append(name: "manifest.json", data: data)
            let explanation = """
            WorshipCue — selected-team cloud personal export

            This ZIP contains your currently authorized cloud personal records, all referenced personal PencilKit archives and PNG previews, and original authorized PDFs needed to interpret those notes. manifest.json links each version/page/geometry to its immutable file, size and SHA-256.

            Native .drawing files require PencilKit-compatible software; previews contain only your ink. Source PDFs preserve their original embedded arranger annotations. This archive is a data bundle, not an automatic restore format or a flattened annotated PDF.

            NOT INCLUDED: unsynced local handwriting, local drafts, standalone/legacy device charts, other teams or inaccessible teams, other people's private records, shared team ink, credentials, or a whole-account backup. Export readable copies of unsynced local notes separately using the music stand's PDF export before deleting local data.

            Keep this archive private. Copy it to your chosen backup destination and retain manifest.json with the files. No account or team content was deleted by creating it.
            """
            try await writer.append(name: "README.txt", data: Data(explanation.utf8))
            try Task.checkCancellation(); try checkContext(); try await writer.finish()
            try Task.checkCancellation(); try checkContext()
            let completed = job.appendingPathComponent("WorshipCue-Personal-Data.zip")
            try FileManager.default.moveItem(at: partial, to: completed)
            return completed
        } catch {
            await writer.abort(); try? FileManager.default.removeItem(at: job)
            if (try? FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty) == true { try? FileManager.default.removeItem(at: directory) }
            throw error
        }
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
        removeCompletedExport(); busy = true; error = nil
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
                    let directory = try team.operationDirectory().appendingPathComponent("personal-data-exports")
                    let file = try await Self.writeBundle(records: assembled, owner: owner, team: selected,
                        unavailableTeams: context["unavailable_team_count"], directory: directory,
                        chart: { try await self.team.accountExportChart($0, expectedScope: scope) },
                        asset: { try await self.team.accountExportAsset($0, expectedScope: scope) },
                        checkContext: {
                            guard captured == self.generation, scope == self.team.scopeID, self.team.session?.userID == owner,
                                  self.team.selectedTeam == selected else { throw RemoteError.authentication }
                        })
                    guard captured == generation, scope == team.scopeID else { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()); return }
                    completedDirectory = file.deletingLastPathComponent()
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

/// ZIP32, stored entries: interoperable without another production dependency.
actor AccountExportArchiveWriter {
    private struct Entry { let name: Data; let bytes: UInt32; let crc: UInt32; let offset: UInt32 }
    private var handle: FileHandle?
    private var entries: [Entry] = []
    private var names = Set<String>()
    private var offset: UInt64 = 0
    private let limit: UInt64
    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xedb8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }
    init(url: URL, maximumBytes: UInt64 = 1_073_741_824) throws {
        limit = min(maximumBytes, UInt64(UInt32.max))
        #if os(iOS)
        let attributes: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        #else
        let attributes: [FileAttributeKey: Any] = [:]
        #endif
        guard !FileManager.default.fileExists(atPath: url.path), FileManager.default.createFile(atPath: url.path, contents: nil,
            attributes: attributes) else { throw CocoaError(.fileWriteUnknown) }
        handle = try FileHandle(forWritingTo: url)
    }
    deinit { try? handle?.close() }
    nonisolated static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8) }
        return crc ^ 0xffff_ffff
    }
    private func fields(_ values: [(UInt32, Int)]) -> Data {
        var data = Data()
        for (value, count) in values { for byte in 0..<count { data.append(UInt8(truncatingIfNeeded: value >> (8 * byte))) } }
        return data
    }
    private func write(_ data: Data) throws {
        try Task.checkCancellation()
        guard let handle, UInt64(data.count) <= limit - min(offset, limit) else { throw RemoteError.tooLarge }
        try handle.write(contentsOf: data); offset += UInt64(data.count)
    }
    func append(name: String, data: Data) throws {
        try Task.checkCancellation()
        guard !name.isEmpty, name.count <= 255, !name.hasPrefix("/"), !name.hasSuffix("/"),
              name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-/._".contains($0)) }),
              name.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              names.insert(name).inserted, entries.count < 65_535, data.count <= 100 * 1024 * 1024,
              offset <= UInt64(UInt32.max) else { throw RemoteError.invalidResponse }
        let nameBytes = Data(name.utf8), size = UInt32(data.count), checksum = Self.crc32(data), start = UInt32(offset)
        try write(fields([(0x0403_4b50, 4), (20, 2), (0, 2), (0, 2), (0, 2), (33, 2),
            (checksum, 4), (size, 4), (size, 4), (UInt32(nameBytes.count), 2), (0, 2)]))
        try write(nameBytes)
        for begin in stride(from: 0, to: data.count, by: 1_048_576) { try write(data.subdata(in: begin..<min(begin + 1_048_576, data.count))) }
        entries.append(Entry(name: nameBytes, bytes: size, crc: checksum, offset: start))
    }
    func finish() throws {
        guard let handle, offset <= UInt64(UInt32.max) else { throw RemoteError.invalidResponse }
        let start = UInt32(offset)
        for entry in entries {
            try write(fields([(0x0201_4b50, 4), (20, 2), (20, 2), (0, 2), (0, 2), (0, 2), (33, 2),
                (entry.crc, 4), (entry.bytes, 4), (entry.bytes, 4), (UInt32(entry.name.count), 2),
                (0, 2), (0, 2), (0, 2), (0, 2), (0, 4), (entry.offset, 4)]))
            try write(entry.name)
        }
        let length = UInt32(offset) - start, count = UInt32(entries.count)
        try write(fields([(0x0605_4b50, 4), (0, 2), (0, 2), (count, 2), (count, 2), (length, 4), (start, 4), (0, 2)]))
        try handle.synchronize(); try handle.close(); self.handle = nil
    }
    func abort() { try? handle?.close(); handle = nil }
}

struct AccountDataExportView: View {
    @ObservedObject var team: TeamWorkspace
    @StateObject private var model: AccountDataExport
    @State private var exportTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss
    init(team: TeamWorkspace) { self.team = team; _model = StateObject(wrappedValue: AccountDataExport(team: team)) }
    var body: some View {
        NavigationStack {
            Form {
                Section("내 개인 자료") {
                    Text("현재 팀에서 접근 가능한 내 클라우드 개인 기록, 필기 원본·미리보기와 해당 악보 PDF를 ZIP으로 저장합니다. 다른 팀과 다른 팀원의 개인 기록은 포함되지 않습니다.")
                    Text("아직 동기화되지 않은 기기 메모와 초안은 포함되지 않습니다. 먼저 악보 화면에서 PDF로 내보내 주세요. 이 ZIP은 자동 복원 파일이 아닙니다.").font(.caption).foregroundStyle(.secondary)
                    Button("현재 팀의 개인 자료 ZIP 내보내기") { exportTask = Task { await model.exportSelectedTeam() } }
                        .disabled(model.busy || team.selectedTeam == nil)
                    if model.busy { Button("내보내기 취소") { exportTask?.cancel(); model.reset() } }
                    if let url = model.exportedURL {
                        Label("개인 자료 ZIP 준비 완료", systemImage: "checkmark.circle")
                        ShareLink(item: url) { Label("개인 자료 ZIP 공유·저장", systemImage: "square.and.arrow.up") }
                        Text("공유·저장으로 보관할 위치를 선택해 주세요. 이 화면을 닫으면 임시 ZIP은 제거됩니다.").font(.caption).foregroundStyle(.secondary)
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
                .onDisappear { exportTask?.cancel(); model.reset() }
        }
    }
}
