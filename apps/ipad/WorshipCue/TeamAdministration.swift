import SwiftUI
import WorshipCueRemote

struct TeamAdminRequest: Codable, Equatable {
    let name: String
    let payload: [String: TeamJSON]
}

/// A timeout retains the exact command for an explicit retry in its original team.
@MainActor final class TeamAdministration: ObservableObject {
    @Published private(set) var members: [TeamJSON] = []
    @Published private(set) var invitations: [TeamJSON] = []
    @Published private(set) var pending: TeamAdminRequest?
    @Published private(set) var pendingFileExists = false
    @Published private(set) var busy = false
    @Published private(set) var hasMoreInvitations = false
    @Published private(set) var error: String?
    private let team: TeamWorkspace
    private var generation = UUID()
    private var invitationCursor: TeamJSON = .null

    init(team: TeamWorkspace) { self.team = team }
    var ownMember: TeamJSON? { members.first { $0["user_id"].uuid == team.session?.userID } }
    var blocked: Bool { busy || pendingFileExists }

    func reset() {
        generation = UUID(); members = []; invitations = []; pending = nil
        pendingFileExists = false; busy = false; error = nil
        hasMoreInvitations = false; invitationCursor = .null
    }
    private func requestFile() throws -> URL {
        try team.operationDirectory().appendingPathComponent("pending-administration.json")
    }
    private func loadPending() throws {
        let path = try requestFile()
        pendingFileExists = FileManager.default.fileExists(atPath: path.path)
        pending = pendingFileExists ? try JSONDecoder().decode(TeamAdminRequest.self, from: Data(contentsOf: path)) : nil
        if let pending { try validate(pending) }
    }
    private func validate(_ request: TeamAdminRequest) throws {
        guard ["set_member_display_name", "set_member_role", "set_membership_active", "handoff_team_admin", "revoke_invitation"].contains(request.name),
              request.payload["command_id"]?.uuid != nil,
              request.payload["team_id"]?.uuid == team.selectedTeam else { throw RemoteError.invalidResponse }
    }
    private func rosterRows(_ value: TeamJSON) throws -> [TeamJSON] {
        guard value["team_id"].uuid == team.selectedTeam, case .array(let rows) = value["members"], rows.count <= 200 else { throw RemoteError.invalidResponse }
        var users = Set<UUID>()
        for row in rows {
            guard let user = row["user_id"].uuid, users.insert(user).inserted,
                  row["church_id"].uuid == team.selectedChurch, row["team_id"].uuid == team.selectedTeam,
                  ["member", "leader", "admin"].contains(row["role"].text ?? ""),
                  case .bool = row["active"], let revision = row["revision"].integer, revision >= 1,
                  let name = row["display_name"].text, name.count <= 120 else { throw RemoteError.invalidResponse }
        }
        return rows
    }
    private func invitationPage(_ value: TeamJSON) throws -> (rows: [TeamJSON], more: Bool, cursor: TeamJSON) {
        guard value["team_id"].uuid == team.selectedTeam, case .array(let rows) = value["invitations"], rows.count <= 100,
              case .bool(let more) = value["has_more"], !more || value["next_invitation_id"].uuid != nil else { throw RemoteError.invalidResponse }
        var ids = Set<UUID>()
        for row in rows {
            guard let id = row["id"].uuid, ids.insert(id).inserted, row["invitation_id"].uuid == id,
                  row["church_id"].uuid == team.selectedChurch, row["team_id"].uuid == team.selectedTeam,
                  ["member", "leader", "guest"].contains(row["permitted_role"].text ?? ""),
                  ["active", "expired", "revoked", "exhausted"].contains(row["status"].text ?? ""),
                  (row["permitted_role"].text == "guest") == (row["setlist_id"].uuid != nil),
                  let revision = row["revision"].integer, revision >= 1,
                  let expiry = row["expires_at"].text, TeamWorkspace.parseDate(expiry) != nil,
                  row["token"] == .null, row["token_hash"] == .null else { throw RemoteError.invalidResponse }
        }
        return (rows, more, value["next_invitation_id"])
    }
    private func validateReceipt(_ value: TeamJSON, for request: TeamAdminRequest) throws {
        guard value["team_id"].uuid == team.selectedTeam else { throw RemoteError.invalidResponse }
        if request.name == "revoke_invitation" {
            guard value["invitation_id"] == request.payload["invitation_id"], value["revoked"] == .bool(true),
                  let revision = value["revision"].integer, revision >= 1 else { throw RemoteError.invalidResponse }
        } else if request.name == "handoff_team_admin" {
            let rows = try rosterRows(value)
            guard rows.count == 2, Set(rows.compactMap { $0["user_id"].uuid }) == Set([team.session?.userID, request.payload["user_id"]?.uuid].compactMap { $0 }) else { throw RemoteError.invalidResponse }
        } else {
            _ = try rosterRows(.object(["team_id": value["team_id"], "members": .array([value])]))
            let target = request.name == "set_member_display_name" ? team.session?.userID : request.payload["user_id"]?.uuid
            guard value["user_id"].uuid == target else { throw RemoteError.invalidResponse }
        }
    }
    func refresh() async {
        guard !busy else { return }
        let captured = generation, scope = team.scopeID
        busy = true; error = nil
        defer { if captured == generation { busy = false } }
        do {
            try loadPending()
            let roster = try await team.rpc("get_team_roster", ["include_inactive": .bool(team.canAdmin)])
            guard captured == generation, scope == team.scopeID else { return }
            let nextMembers = try rosterRows(roster)
            let page: ([TeamJSON], Bool, TeamJSON)
            if team.canAdmin { page = try await fetchInvitations(more: false) }
            else { page = ([], false, .null) }
            guard captured == generation, scope == team.scopeID else { return }
            members = nextMembers; invitations = page.0
            hasMoreInvitations = page.1; invitationCursor = page.2
        } catch { if captured == generation, scope == team.scopeID { report(error) } }
    }
    private func fetchInvitations(more: Bool) async throws -> ([TeamJSON], Bool, TeamJSON) {
        guard team.canAdmin else { throw RemoteError.forbidden }
        var payload: [String: TeamJSON] = ["limit": .int(50)]
        if more, invitationCursor != .null { payload["after_invitation_id"] = invitationCursor }
        let result = try await team.rpc("get_team_invitations", payload)
        let page = try invitationPage(result)
        return (page.rows, page.more, page.cursor)
    }
    func moreInvitations() async {
        guard !busy, hasMoreInvitations else { return }
        let captured = generation, scope = team.scopeID
        busy = true; defer { if captured == generation { busy = false } }
        do {
            let page = try await fetchInvitations(more: true)
            guard captured == generation, scope == team.scopeID else { return }
            let existing = Set(invitations.compactMap { $0["id"].uuid })
            invitations += page.0.filter { !existing.contains($0["id"].uuid!) }
            hasMoreInvitations = page.1; invitationCursor = page.2
        }
        catch { if captured == generation, scope == team.scopeID { report(error) } }
    }
    func submit(_ name: String, _ values: [String: TeamJSON]) async {
        guard !busy else { return }
        do {
            try loadPending()
            guard !pendingFileExists, let teamID = team.selectedTeam else { throw RemoteError.conflict }
            var payload = values; payload["team_id"] = .id(teamID); payload["command_id"] = .id(UUID())
            let request = TeamAdminRequest(name: name, payload: payload)
            try validate(request)
            try JSONEncoder().encode(request).write(to: requestFile(), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            pending = request; pendingFileExists = true
        } catch { report(error); return }
        await retry()
    }
    func retry() async {
        guard !busy else { return }
        let captured = generation, scope = team.scopeID
        busy = true; error = nil
        defer { if captured == generation { busy = false } }
        do {
            try loadPending()
            guard let pending else { throw RemoteError.invalidResponse }
            let receipt = try await team.rpc(pending.name, pending.payload)
            guard captured == generation, scope == team.scopeID else { return }
            try validateReceipt(receipt, for: pending)
            try FileManager.default.removeItem(at: requestFile())
            self.pending = nil; pendingFileExists = false
            // A handoff can change our role; refresh membership before privileged reads.
            await team.refresh()
            guard captured == generation, scope == team.scopeID else { return }
            busy = false
            await refresh()
        } catch { if captured == generation, scope == team.scopeID { report(error) } }
    }
    func discard() {
        guard !busy else { return }
        do { try FileManager.default.removeItem(at: requestFile()); pending = nil; pendingFileExists = false; error = nil }
        catch { report(error) }
    }
    private func report(_ value: Error) {
        if let value = value as? RemoteError, value == .conflict {
            error = String(localized: "변경 내용이 달라졌거나 확인할 요청이 남아 있어요. 팀 자료를 다시 확인해 주세요.")
        } else if let value = value as? RemoteError, value == .server("TEAM_ADMIN_REQUIRED") {
            error = String(localized: "팀에는 관리자가 한 명 이상 남아 있어야 합니다. 먼저 다른 팀원에게 관리자 권한을 넘겨 주세요.")
        } else if let value = value as? RemoteError, value == .forbidden || value == .authentication {
            members = []; invitations = []; hasMoreInvitations = false; invitationCursor = .null
            error = String(localized: "이 팀을 관리할 권한을 다시 확인해 주세요.")
        } else {
            error = String(localized: "연결과 저장 상태를 확인해 주세요. 저장된 요청은 직접 다시 시도할 수 있어요.")
        }
    }
}

struct TeamAdministrationView: View {
    @ObservedObject var team: TeamWorkspace
    @StateObject private var model: TeamAdministration
    @Environment(\.dismiss) private var dismiss
    @State private var displayName = ""
    @State private var initializedName = false
    @State private var confirmation: AdminConfirmation?
    init(team: TeamWorkspace) { self.team = team; _model = StateObject(wrappedValue: TeamAdministration(team: team)) }

    var body: some View {
        NavigationStack {
            Form {
                if let error = model.error { Section { Text(error).foregroundStyle(.orange) } }
                if model.pendingFileExists {
                    Section("확인 대기 중인 요청") {
                        Text("응답이 끊겨도 같은 요청을 보관합니다. 연결되었다고 자동으로 다시 실행하지 않습니다.").font(.caption)
                        Button("저장된 요청 다시 시도") { Task { await model.retry() } }.disabled(model.busy || model.pending == nil)
                        Button("저장된 요청 삭제", role: .destructive) { confirmation = .discard }
                            .disabled(model.busy)
                        Text("요청을 삭제해도 서버에서 이미 완료된 변경은 취소되지 않습니다.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let own = model.ownMember {
                    Section("내 표시 이름") {
                        TextField("팀에서 사용할 이름", text: $displayName).onChange(of: displayName) { displayName = String($0.prefix(120)) }
                        Button("표시 이름 저장") { Task { await model.submit("set_member_display_name", ["expected_revision": own["revision"], "display_name": .string(displayName.trimmingCharacters(in: .whitespacesAndNewlines))]) } }
                            .disabled(model.blocked || displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                Section("팀원") {
                    ForEach(Array(model.members.enumerated()), id: \.offset) { _, member in memberCard(member) }
                }
                if team.canAdmin {
                    Section("초대 관리") {
                        if model.invitations.isEmpty { Text("보관된 초대가 없어요.").foregroundStyle(.secondary) }
                        ForEach(Array(model.invitations.enumerated()), id: \.offset) { _, invitation in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(roleName(invitation["permitted_role"].text))
                                    if let created = invitation["created_at"].text.flatMap(TeamWorkspace.parseDate) {
                                        HStack { Text("발급"); Text(created, format: .dateTime.month().day().hour().minute()) }.font(.caption).foregroundStyle(.secondary)
                                    }
                                    if let expiry = invitation["expires_at"].text.flatMap(TeamWorkspace.parseDate) {
                                        HStack { Text("만료"); Text(expiry, format: .dateTime.month().day().hour().minute()) }.font(.caption).foregroundStyle(.secondary)
                                    }
                                    if let used = invitation["used_count"].integer, let maximum = invitation["max_uses"].integer {
                                        HStack { Text("사용 횟수"); Text("\(used) / \(maximum)") }.font(.caption).foregroundStyle(.secondary)
                                    }
                                    Text(invitation["status"].text.map(invitationStatus) ?? (invitation["revoked_at"] != .null ? String(localized: "취소됨") : String(localized: "초대"))).font(.caption)
                                }
                                Spacer()
                                if invitation["revoked_at"] == .null, invitation["status"].text == "active" {
                                    Button("초대 취소", role: .destructive) { confirmation = .revoke(invitation) }.disabled(model.blocked)
                                }
                            }.frame(minHeight: 44)
                        }
                        if model.hasMoreInvitations { Button("초대 더 확인") { Task { await model.moreInvitations() } }.disabled(model.busy) }
                        Text("초대 원본 코드는 다시 노출하지 않습니다. 초대 취소는 이미 참여한 팀원을 제거하지 않습니다.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.navigationTitle("팀원·초대 관리")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) { Button("새로 확인") { Task { await model.refresh() } }.disabled(model.busy) } }
                .task { await load() }
                .onChange(of: team.scopeID) { _ in model.reset(); initializedName = false; displayName = ""; confirmation = nil; Task { await load() } }
                .alert("변경을 확인해 주세요", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })) {
                    if let value = confirmation { Button("확인", role: .destructive) { confirmation = nil; Task { await confirm(value) } } }
                    Button("취소", role: .cancel) { confirmation = nil }
                } message: { Text(confirmation?.question ?? "") }
        }
    }
    private func load() async {
        await model.refresh()
        if !initializedName, let own = model.ownMember { displayName = own["display_name"].text ?? ""; initializedName = true }
    }
    private func memberCard(_ member: TeamJSON) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(member["display_name"].text.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "이름 미설정"))
            Text(roleName(member["role"].text) + (member["active"].flag ? "" : " · " + String(localized: "참여 해제됨"))).font(.caption).foregroundStyle(.secondary)
            if team.canAdmin {
                HStack {
                    if member["active"].flag {
                        Menu("권한 변경") { ForEach(["member", "leader", "admin"], id: \.self) { role in
                            if member["role"].text != role { Button(roleName(role)) { confirmation = .role(member, role) } }
                        } }.disabled(model.blocked).frame(minHeight: 44)
                    }
                    if member["user_id"].uuid != team.session?.userID {
                        if member["active"].flag {
                            Button("관리자 넘기기") { confirmation = .handoff(member) }.disabled(model.blocked).frame(minHeight: 44)
                        }
                        Button(member["active"].flag ? "참여 해제" : "다시 참여 허용", role: member["active"].flag ? .destructive : nil) {
                            confirmation = .active(member, !member["active"].flag)
                        }.disabled(model.blocked).frame(minHeight: 44)
                    }
                }
            }
        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }
    private func confirm(_ value: AdminConfirmation?) async {
        guard let value else { return }
        switch value {
        case .discard: model.discard()
        case .role(let member, let role): await model.submit("set_member_role", ["user_id": member["user_id"], "expected_revision": member["revision"], "role": .string(role)])
        case .active(let member, let active): await model.submit("set_membership_active", ["user_id": member["user_id"], "expected_revision": member["revision"], "active": .bool(active)])
        case .handoff(let member):
            guard let own = model.ownMember else { return }
            await model.submit("handoff_team_admin", ["user_id": member["user_id"], "expected_self_revision": own["revision"], "expected_member_revision": member["revision"]])
        case .revoke(let invitation): await model.submit("revoke_invitation", ["invitation_id": invitation["id"], "expected_revision": invitation["revision"]])
        }
    }
    private func roleName(_ value: String?) -> String {
        switch value { case "admin": return String(localized: "관리자"); case "leader": return String(localized: "진행자"); case "guest": return String(localized: "게스트"); default: return String(localized: "팀원") }
    }
    private func invitationStatus(_ value: String) -> String {
        switch value { case "revoked": return String(localized: "취소됨"); case "expired": return String(localized: "만료됨"); case "exhausted": return String(localized: "사용 완료"); default: return String(localized: "사용 가능") }
    }
}

private enum AdminConfirmation {
    case discard, role(TeamJSON, String), active(TeamJSON, Bool), handoff(TeamJSON), revoke(TeamJSON)
    var question: String {
        switch self {
        case .discard: return String(localized: "저장된 요청을 삭제할까요? 서버에서 완료된 변경은 취소되지 않습니다.")
        case .role: return String(localized: "이 팀원의 권한을 변경할까요? 마지막 관리자는 남겨야 합니다.")
        case .active(_, let active): return active ? String(localized: "이 팀원에게 이 팀의 자료와 대화를 다시 허용할까요?") : String(localized: "이 팀원의 자료·대화 접근을 해제할까요? 공유 자료는 보존됩니다.")
        case .handoff: return String(localized: "선택한 팀원에게 관리자 권한을 넘길까요? 내 권한은 진행자로 바뀝니다.")
        case .revoke: return String(localized: "이 초대의 추가 사용을 막을까요? 이미 참여한 팀원은 유지됩니다.")
        }
    }
}
