import SwiftUI
import WorshipCueCore
import WorshipCueLocal
import WorshipCueRemote

struct TeamPanel: View {
    @ObservedObject var team: TeamWorkspace
    @ObservedObject var local: MusicStand
    let opened: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var code = ""
    @State private var invitation = ""
    @State private var workspaceName = ""
    @State private var codeSent = false
    @State private var sessions: [TeamRow] = []
    @State private var inviteToken: String?
    @State private var inviteRole = "member"
    @State private var inviteSetlist: UUID?
    @State private var publishSheet = false
    @State private var setlistSheet = false
    @State private var controllerSheet = false
    @State private var query = ""
    @State private var chatSheet = false
    @State private var teamName = ""
    @State private var memberName = ""
    @State private var administrationSheet = false
    @State private var accountExportSheet = false
    @State private var discardPublication: TeamRow?
    @State private var guestLogout = false
    @State private var entryChoice = ""
    @State private var showLogin = false
    @State private var showCreate = false
    @State private var showJoin = false
    @State private var recoveryHelp = false
    @State private var preparationSheet = false

    var body: some View {
        NavigationStack {
            Form {
                if let error = team.error {
                    Section("확인이 필요해요") {
                        Text(error).foregroundStyle(.orange)
                        if let recovery = team.recovery { Button(recovery.actionTitle) { recover(recovery) }.frame(minHeight: 44) }
                        if recoveryHelp { Text("기기 저장 공간은 iPad 설정에서 확인할 수 있어요. 팀 권한·초대나 로그인 이메일은 관리자와 확인해 주세요. 확인 중에도 기기의 원본과 메모는 보관됩니다.").font(.caption) }
                        Button("닫기") { team.error = nil; recoveryHelp = false }
                    }
                }
                if !team.configured {
                    Section {
                        Label("팀 연결 준비 중", systemImage: "person.2")
                        Text("이 기기의 악보·필기·예배 목록을 계속 사용할 수 있어요. 팀 연결은 개발용 서버가 준비되면 사용할 수 있습니다.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                } else if team.session == nil {
                    Section("처음 시작") {
                        Text("내 PDF는 로그인 없이 사용할 수 있어요. 팀 연결은 원하는 때 선택하세요.").font(.subheadline)
                        Button("내 기기 PDF로 시작") { Task { if await team.useLocalReader() { opened(); dismiss() } } }.frame(minHeight: 44)
                        Button("초대받은 교회·팀에 참여") { entryChoice = "join" }.frame(minHeight: 44)
                        Button("새 교회·팀 만들기") { entryChoice = "create" }.frame(minHeight: 44)
                    }
                    if !entryChoice.isEmpty { Section(entryChoice == "create" ? "팀을 만들 계정 확인" : "팀원 계정 확인") {
                        Text(entryChoice == "create" ? "이메일 인증 후 새 비공개 교회·팀을 만들 수 있어요." : "이메일 인증 후 관리자에게 받은 초대 코드를 입력하세요.").font(.caption).foregroundStyle(.secondary)
                        TextField("이메일", text: $email).textInputAutocapitalization(.never).keyboardType(.emailAddress).autocorrectionDisabled()
                            .accessibilityIdentifier("teamEmail")
                        if codeSent {
                            TextField("인증 번호", text: $code).keyboardType(.numberPad).textContentType(.oneTimeCode).accessibilityIdentifier("teamCode")
                            Button("로그인") { Task { if await team.signIn(email, code: code) { showCreate = entryChoice == "create"; showJoin = entryChoice == "join"; await reloadSessions() } } }.disabled(code.count < 6)
                        }
                        Button(codeSent ? "인증 번호 다시 받기" : "인증 번호 받기") { Task { codeSent = await team.sendCode(email) } }
                            .disabled(email.isEmpty).accessibilityIdentifier("sendTeamCode")
                    }
                    }
                    if entryChoice == "join" { Section("이번 예배만 게스트로 참여") {
                        TextField("팀에서 사용할 이름", text: $memberName).textContentType(.name)
                        TextField("초대 코드", text: $invitation).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("초대한 예배에 참여") { Task { if await team.redeem(invitation, guest: true, displayName: memberName) { await reloadSessions() } } }.disabled(invitation.isEmpty || memberName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || memberName.count > 120)
                        Text("게스트는 초대받은 예배의 자료만 볼 수 있어요. 개인 메모는 이 기기에 저장됩니다.").font(.caption)
                    } }
                } else {
                    Section("현재 교회·팀") {
                        Text(team.selectedWorkspaceName).font(.headline)
                        Text(team.selectedChurchName + " · " + team.selectedRoleLabel).font(.subheadline).foregroundStyle(.secondary)
                        if let checked = team.connectionCheckedAt { HStack { Text("마지막 팀 확인"); Text(checked, style: .time) }.font(.caption) }
                        Label(team.message, systemImage: team.online ? "checkmark.icloud" : "icloud.slash")
                        Button("팀 자료 새로 확인") { Task { await team.refresh(); await reloadSessions() } }
                        Button("내 기기 악보로 돌아가기") { Task { if await team.useLocalReader() { opened(); dismiss() } } }
                    }
                    if showLogin {
                        Section("같은 계정으로 다시 로그인") {
                            TextField("이메일", text: $email).textInputAutocapitalization(.never).keyboardType(.emailAddress).autocorrectionDisabled()
                            TextField("인증 번호", text: $code).keyboardType(.numberPad).textContentType(.oneTimeCode)
                            Button("인증 번호 받기") { Task { codeSent = await team.sendCode(email) } }.disabled(email.isEmpty)
                            Button("로그인 확인") { Task { if await team.signIn(email, code: code) { showLogin = false } } }.disabled(code.count < 6)
                            Text("다른 계정은 기기 메모를 내보내고 로그아웃한 뒤 선택하세요.").font(.caption)
                        }
                    }
                    if team.selectedTeam != nil {
                        Section("팀 바로가기") {
                            NavigationLink("예배 준비 확인") { Form { ForEach(team.setlists) { setlist in Section { TeamPreparationChecklist(team: team, setlist: setlist) } } }.navigationTitle("예배 준비 확인") }
                            NavigationLink("팀 곡 라이브러리") { Form { teamLibrary }.navigationTitle("팀 곡 라이브러리") }
                            if team.session?.anonymous == false { Button("팀 대화 열기") { chatSheet = true }.frame(minHeight: 44) }
                        }
                    }
                    if !team.memberships.isEmpty {
                        Section("내 팀") {
                            ForEach(Array(team.memberships.enumerated()), id: \.offset) { _, membership in
                                Button { Task { await team.chooseWorkspace(membership); await reloadSessions() } } label: {
                                    HStack {
                                        VStack(alignment: .leading) {
                                            Text(membership["team_name"].text ?? String(localized: "초대받은 팀"))
                                            Text((membership["church_name"].text ?? String(localized: "교회 이름 확인 필요")) + " · " + TeamWorkspace.roleLabel(membership["role"].text)).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if membership["church_id"].uuid == team.selectedChurch && membership["team_id"].uuid == team.selectedTeam { Image(systemName: "checkmark") }
                                    }
                                }
                            }
                        }
                    }
                    if !team.session!.anonymous {
                        Section { DisclosureGroup("새 교회·팀 만들기", isExpanded: $showCreate) {
                            TextField("교회 이름", text: $workspaceName)
                            TextField("팀에서 사용할 이름", text: $memberName).textContentType(.name)
                            Button("새 비공개 교회·팀 만들기") { Task { _ = await team.createWorkspace(workspaceName, memberDisplayName: memberName) } }
                                .disabled(workspaceName.isEmpty || memberName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || memberName.count > 120)
                        } }
                    }
                    if team.canAdmin {
                        Section("같은 교회에 팀 추가") {
                            TextField("팀 이름", text: $teamName)
                            Button("새 비공개 팀 만들기") { Task { if await team.createTeam(teamName) { teamName = ""; await reloadSessions() } } }.disabled(teamName.isEmpty)
                            Text("팀마다 악보·대화·예배 목록을 따로 보관합니다.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if team.session?.anonymous == false, team.selectedTeam != nil {
                        Section {
                            Button { administrationSheet = true } label: { Label(team.canAdmin ? String(localized: "내 이름·팀원·초대 관리") : String(localized: "내 이름·팀원 보기"), systemImage: "person.crop.circle") }.frame(minHeight: 44)
                        }
                        Section("팀 대화") {
                            Button { chatSheet = true } label: { HStack { Label("팀 대화 열기", systemImage: "bubble.left.and.bubble.right"); Spacer(); if let unread = team.chatUnreadSummary { Text(unread).font(.caption.bold()).padding(6).background(Color.blue.opacity(0.12), in: Capsule()).accessibilityLabel(String(localized: "읽지 않은 대화: ") + unread) } } }.frame(minHeight: 44)
                        }
                    }
                    Section { DisclosureGroup("초대 코드로 다른 팀에 참여", isExpanded: $showJoin) {
                        TextField("팀에서 사용할 이름", text: $memberName).textContentType(.name)
                        TextField("초대 코드", text: $invitation).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("참여") { Task { _ = await team.redeem(invitation, guest: false, displayName: memberName); await reloadSessions() } }.disabled(invitation.isEmpty || memberName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || memberName.count > 120)
                    } }
                    Section("진행 중인 예배") {
                        if sessions.isEmpty { Text("진행 중인 예배가 없어요.").foregroundStyle(.secondary) }
                        ForEach(sessions.filter { $0.value["status"].text == "LIVE" }) { session in
                            Button("\(team.setlists.first { $0.id == session.value["setlist_id"].uuid }?.value["title"].text ?? String(localized: "예배")) · 안내 받기") {
                                Task { if await team.joinSession(session.id) { dismiss() } }
                            }
                        }
                    }
                    if !team.pendingPublications.isEmpty {
                        Section("게시 확인 대기") {
                            Text("연결이 끊겨도 원본과 같은 게시 요청을 보관합니다. 직접 다시 시도하면 완료 여부를 확인하며 중복 게시하지 않습니다.").font(.caption)
                            ForEach(team.pendingPublications) { publication in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(publication.value["title"].text ?? "").font(.headline)
                                    if publication.value["completed"].flag { Label("게시 완료 · 목록 확인 대기", systemImage: "checkmark.circle") }
                                    HStack {
                                        Button("같은 요청 다시 확인") { Task { _ = await team.retryPublication(publication) } }.disabled(!team.canLead && !publication.value["completed"].flag)
                                        Spacer()
                                        Button("기기의 요청 삭제", role: .destructive) { discardPublication = publication }
                                    }
                                }.padding(.vertical, 4)
                            }
                        }
                    }
                    if team.canLead {
                        Section("팀 준비·진행") {
                            Button("이 기기의 PDF를 팀에 게시") { publishSheet = true }
                            Button("팀 예배 목록 만들기·수정") { setlistSheet = true }
                            Button("곡 안내·팀 메모") { controllerSheet = true }
                        }
                    }
                    if team.canAdmin {
                        Section("초대 만들기") {
                            Picker("권한", selection: $inviteRole) { Text("팀원").tag("member"); Text("진행자").tag("leader"); Text("게스트").tag("guest") }
                            Text(inviteRole == "guest" ? "게스트는 초대한 예배 자료만 봅니다." : (inviteRole == "leader" ? "진행자는 팀 악보 게시·곡 안내·팀 메모를 진행합니다." : "팀원은 팀 자료·대화를 사용하고 개인 메모를 남깁니다.")).font(.caption).foregroundStyle(.secondary)
                            if inviteRole == "guest" {
                                Picker("초대 예배", selection: $inviteSetlist) {
                                    Text("예배 선택").tag(nil as UUID?)
                                    ForEach(team.setlists) { Text($0.value["title"].text ?? "").tag(Optional($0.id)) }
                                }
                            }
                            Button("한 번 사용 · 7일 초대 만들기") { Task { inviteToken = await team.invite(role: inviteRole, setlistID: inviteRole == "guest" ? inviteSetlist : nil) } }
                                .disabled(inviteRole == "guest" && inviteSetlist == nil)
                            if let inviteToken {
                                Text(inviteToken).font(.footnote.monospaced()).textSelection(.enabled)
                                ShareLink(item: String(localized: "WorshipCue iPad 앱에서 이 초대 코드를 입력해 주세요: ") + inviteToken)
                                Text("이 코드는 다시 표시되지 않아요. 초대한 사람에게만 전달해 주세요.").font(.caption)
                            }
                        }
                    }
                    if team.session?.anonymous == false {
                        Section {
                            Button("내 개인 메모 동기화 확인") { Task { await team.syncPersonal() } }
                            Button("개인 메모 충돌 확인") { team.showConflicts = true }
                        }
                        if team.isAWS {
                            Section("내 계정 자료") {
                                Button { accountExportSheet = true } label: { Label("내 자료 내보내기·관리자 확인", systemImage: "person.crop.circle.badge.checkmark") }.frame(minHeight: 44)
                            }
                        }
                    }
                    Section { Button("로그아웃", role: .destructive) {
                        if team.session?.anonymous == true { guestLogout = true }
                        else { Task { _ = await team.logout() } }
                    } }
                }
            }.disabled(team.busy)
                .navigationTitle("팀 작업 공간")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("닫기") { dismiss() }.frame(minHeight: 44) } }
                .task { if team.memberships.isEmpty && entryChoice == "create" { showCreate = true }; if team.memberships.isEmpty && entryChoice == "join" { showJoin = true }; await reloadSessions(); await team.refreshChatRooms() }
                .onChange(of: team.scopeID) { _ in sessions = []; inviteToken = nil; inviteSetlist = nil; query = ""; Task { await reloadSessions() } }
                .sheet(isPresented: $preparationSheet) {
                    NavigationStack {
                        Form { ForEach(team.setlists) { setlist in Section { TeamPreparationChecklist(team: team, setlist: setlist) } } }
                            .navigationTitle("예배 준비 확인")
                            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("닫기") { preparationSheet = false } } }
                    }
                }
                .sheet(isPresented: $administrationSheet) { TeamAdministrationView(team: team) }
                .sheet(isPresented: $accountExportSheet) { AccountDataExportView(team: team) }
                .alert("기기의 게시 요청을 삭제할까요?", isPresented: Binding(get: { discardPublication != nil }, set: { if !$0 { discardPublication = nil } })) {
                    Button("취소", role: .cancel) { discardPublication = nil }
                    Button("요청 삭제", role: .destructive) { if let row = discardPublication { Task { _ = await team.discardPublication(row) } }; discardPublication = nil }
                } message: { Text("서버에서 이미 완료된 게시나 만들어진 빈 목록은 취소되지 않습니다. 팀 자료를 먼저 확인해 주세요. 이 기기의 원본 PDF와 개인 메모는 유지됩니다.") }
                .alert("게스트에서 로그아웃할까요?", isPresented: $guestLogout) {
                    Button("취소", role: .cancel) {}
                    Button("게스트 로그아웃", role: .destructive) { Task { _ = await team.logout() } }
                } message: { Text("이 게스트 계정으로 다시 로그인할 수 없으며 같은 초대를 다시 사용할 수 없을 수 있어요. 필요한 개인 메모를 PDF로 내보낸 뒤 로그아웃해 주세요.") }
                .sheet(isPresented: $publishSheet) { TeamPublishSheet(team: team, local: local) }
                .sheet(isPresented: $setlistSheet) { TeamSetlistSheet(team: team) }
                .sheet(isPresented: $chatSheet) { TeamChatView(team: team) { opened(); dismiss() } }
                .sheet(isPresented: $controllerSheet) { TeamControllerSheet(team: team) }
                .sheet(isPresented: $team.showConflicts) { PersonalConflictSheet(team: team) }
        }.preferredColorScheme(.light)
    }
    private var teamLibrary: some View {
        Section("팀 악보") {
                        TextField("곡 검색", text: $query).accessibilityIdentifier("teamSearch")
                        ForEach(team.songs.filter { query.isEmpty || KoreanSearch.score(query: query, title: $0.value["canonical_title"].text ?? "", aliases: []) != nil }) { song in
                            DisclosureGroup(team.songTitle(song.id)) {
                                ForEach(team.versionsForSong(song.id)) { version in
                                    HStack {
                                        Button("v\(version.value["version_number"].integer ?? 0) · \(version.value["written_key"].text ?? "?") · \(version.value["label"].text ?? "")") {
                                            Task { if await team.openVersion(version.id) { opened(); dismiss() } }
                                        }.frame(minHeight: 44)
                                        Spacer()
                                        Button { Task { await team.prefer(version.id) } } label: {
                                            Image(systemName: team.preferredVersions[song.id] == version.id ? "star.fill" : "star").frame(width: 44, height: 44)
                                        }.buttonStyle(.borderless).accessibilityLabel(Text("내 기본 악보로 지정"))
                                    }
                                }
                            }
                        }
                        if team.songs.isEmpty { Text("아직 공유한 악보가 없어요.").foregroundStyle(.secondary) }
                    }
    }
    private func recover(_ kind: TeamRecovery) {
        switch kind {
        case .authentication: if team.session?.anonymous == true { showJoin = true; recoveryHelp = true } else { showLogin = true; entryChoice = "join" }
        case .permission: showJoin = true; recoveryHelp = true
        case .configuration: entryChoice = "join"; showLogin = team.session != nil; recoveryHelp = true
        case .integrity: preparationSheet = true
        case .storage, .capacity: recoveryHelp = true
        default: Task { await team.refresh(); await reloadSessions() }
        }
    }
    private func reloadSessions() async {
        guard team.session != nil, team.selectedTeam != nil else { sessions = []; return }
        let captured = team.scopeID, values = await team.sessions()
        guard captured == team.scopeID else { return }
        sessions = values
    }
}

struct TeamPreparationChecklist: View {
    @ObservedObject var team: TeamWorkspace
    let setlist: TeamRow
    private var evidence: TeamPreparation? { team.preparation(setlist.id) }
    private var charts: [TeamPreparedChart] { team.preparationCharts(setlist.id) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(setlist.value["title"].text ?? String(localized: "예배")).font(.headline)
            Text("기기 PDF 검증 \(charts.filter { $0.pdfVerifiedAt != nil }.count) / \(charts.count)").font(.subheadline).monospacedDigit()
            Text("메모 확인 \(charts.filter { $0.notesCheckedAt != nil && $0.personalCheckedAt != nil }.count) / \(charts.count)").font(.subheadline).monospacedDigit()
            Text("기기 PDF와 팀 메모의 최신 확인은 서로 다른 상태입니다. 확인 시각 이후 팀 메모가 바뀔 수 있어요.").font(.caption).foregroundStyle(.secondary)
            if let checked = evidence?.checkedAt {
                HStack { Text("마지막 예배 자료 확인"); Text(checked, format: .dateTime.month().day().hour().minute()) }.font(.caption)
            }
            if evidence?.needsReview == true { Label("일부 자료를 다시 확인해 주세요", systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(.orange) }
            if charts.isEmpty { Text("이 예배에 준비할 곡이 없어요.").foregroundStyle(.secondary) }
            ForEach(charts) { chart in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(chart.title).font(.subheadline.bold())
                            Text(chart.label + (chart.personalPreferred ? " · " + String(localized: "내 기본 악보") : "")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if team.preparationProgress?.setlistID == setlist.id, team.preparationProgress?.chartID == chart.id { ProgressView().accessibilityLabel("이 악보 확인 중") }
                    }
                    Label(chart.pdfVerifiedAt == nil ? String(localized: "PDF 기기 검증 필요") : String(localized: "PDF 기기 저장·검증됨"), systemImage: chart.pdfVerifiedAt == nil ? "arrow.down.doc" : "checkmark.shield")
                    if let checked = chart.notesCheckedAt {
                        HStack { Label("팀 메모 확인", systemImage: "person.2"); Text(checked, style: .time) }
                    } else { Label("팀 메모 확인 필요", systemImage: "person.2.badge.gearshape") }
                    if chart.personalCheckedAt == nil { Label("개인 메모 확인 필요 · 기기 메모 유지", systemImage: "lock") }
                    if let failure = chart.failure { Text(failure.actionTitle).foregroundStyle(.orange) }
                    Button(chart.failure == nil ? "이 악보 다시 확인" : "이 악보 다시 시도") { Task { _ = await team.retryPreparation(setlistID: setlist.id, versionID: chart.id) } }
                        .frame(minHeight: 44).disabled(team.busy).accessibilityLabel(Text("\(chart.title) · 이 악보 다시 확인"))
                }.font(.caption).padding(10).background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            }
            Button("이 예배 모두 준비·확인") { Task { _ = await team.prepare(setlist) } }
                .buttonStyle(.borderedProminent).frame(minHeight: 44).disabled(team.busy || charts.isEmpty)
                .accessibilityIdentifier("prepareSetlist")
        }.task(id: team.scopeID) { await team.refreshPreparationEvidence(setlist.id) }
    }
}

struct TeamPublishSheet: View {
    @ObservedObject var team: TeamWorkspace
    @ObservedObject var local: MusicStand
    @State private var versionID: UUID?
    @State private var songID: UUID?
    @State private var authorized = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("이 기기의 악보", selection: $versionID) {
                        Text("악보 선택").tag(nil as UUID?)
                        ForEach(local.library.versions) { Text($0.label).tag(Optional($0.id)) }
                    }
                    Picker("팀의 곡", selection: $songID) {
                        Text("새 곡으로 게시").tag(nil as UUID?)
                        ForEach(team.songs) { Text(team.songTitle($0.id)).tag(Optional($0.id)) }
                    }
                    Text("선택한 원본 PDF가 새 버전으로 게시됩니다. 편곡자의 원본 메모는 포함하며 개인 필기는 포함하지 않습니다.")
                    Toggle("이 PDF를 팀에 공유할 권한이 있어요", isOn: $authorized)
                    if let error = team.error { Text(error).foregroundStyle(.orange) }
                    Button("원본 PDF 게시") { Task { if let versionID, await team.publish(local, versionID: versionID, songID: songID) { dismiss() } } }
                        .disabled(!authorized || versionID == nil || team.busy)
                }
            }.navigationTitle("팀 악보 게시")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } } }
        }
    }
}

struct TeamItemDraft: Identifiable {
    let id: UUID
    var versionID: UUID
    var key: String
    var standby: Bool
}

struct TeamSetlistSheet: View {
    @ObservedObject var team: TeamWorkspace
    @State private var selected: UUID?
    @State private var title = ""
    @State private var revision: Int64 = 0
    @State private var entries: [TeamItemDraft] = []
    @State private var adding: UUID?
    @State private var standby = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("예배 목록", selection: $selected) {
                        Text("새 예배 목록").tag(nil as UUID?)
                        ForEach(team.setlists) { Text($0.value["title"].text ?? "").tag(Optional($0.id)) }
                    }.onChange(of: selected) { _ in load() }
                    TextField("예배 이름", text: $title)
                }
                Section("곡과 예비곡") {
                    ForEach($entries) { $entry in
                        VStack(alignment: .leading) {
                            Text(team.versions.first { $0.id == entry.versionID }?.value["label"].text ?? "")
                            HStack {
                                TextField("연주 키", text: $entry.key).textInputAutocapitalization(.characters).frame(width: 80)
                                Toggle("예비곡", isOn: $entry.standby)
                            }
                        }.padding(.vertical, 4)
                    }.onDelete { entries.remove(atOffsets: $0) }.onMove { entries.move(fromOffsets: $0, toOffset: $1) }
                    Picker("추가할 팀 악보", selection: $adding) {
                        Text("악보 선택").tag(nil as UUID?)
                        ForEach(team.versions) { version in
                            Text("\(team.songTitle(version.value["song_id"].uuid ?? version.id)) · v\(version.value["version_number"].integer ?? 0) · \(version.value["written_key"].text ?? "?")").tag(Optional(version.id))
                        }
                    }
                    Toggle("예비곡으로 추가", isOn: $standby)
                    Button("목록에 추가") {
                        guard let adding else { return }
                        entries.append(TeamItemDraft(id: UUID(), versionID: adding, key: team.versions.first { $0.id == adding }?.value["written_key"].text ?? "", standby: standby))
                    }.disabled(adding == nil)
                }
                if let error = team.error { Text(error).foregroundStyle(.orange) }
                Section { Button("팀 예배 목록 저장") { Task { if await team.saveSetlist(id: selected, title: title, revision: revision, entries: entries) { dismiss() } } }
                    .disabled(title.isEmpty || !entries.allSatisfy { MusicalKey.isValid($0.key) } || team.busy) }
            }.navigationTitle("팀 예배 목록")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }; ToolbarItem(placement: .primaryAction) { EditButton() } }
        }
    }
    private func load() {
        title = team.setlists.first { $0.id == selected }?.value["title"].text ?? ""
        revision = team.setlists.first { $0.id == selected }?.value["revision"].integer ?? 0
        entries = team.items.filter { $0.value["setlist_id"].uuid == selected && $0.value["active"].flag && ["planned", "standby"].contains($0.value["kind"].text ?? "") }.sorted { ($0.value["position"].integer ?? Int64.max) < ($1.value["position"].integer ?? Int64.max) }.compactMap {
            guard let version = $0.value["team_chart_version_id"].uuid else { return nil }
            return TeamItemDraft(id: $0.id, versionID: version, key: $0.value["performance_key"].text ?? "", standby: $0.value["kind"].text == "standby")
        }
    }
}

struct TeamControllerSheet: View {
    @ObservedObject var team: TeamWorkspace
    @State private var setlistID: UUID?
    @State private var versionID: UUID?
    @State private var itemID: UUID?
    @State private var key = ""
    @State private var takeover = false
    @State private var editor = false
    @Environment(\.dismiss) private var dismiss
    private var selectedHasLease: Bool { team.hasLease && team.lease["setlist_id"].uuid == setlistID }
    private var selectedIsLive: Bool { team.live?.ended == false && team.snapshot["setlist_id"].uuid == setlistID }
    var body: some View {
        NavigationStack {
            Form {
                Section("진행 권한") {
                    Picker("예배", selection: $setlistID) { Text("예배 선택").tag(nil as UUID?); ForEach(team.setlists) { Text($0.value["title"].text ?? "").tag(Optional($0.id)) } }
                        .onChange(of: setlistID) { _ in itemID = nil; versionID = nil; key = "" }
                    Button("이 iPad로 진행 권한 요청") { Task { if let setlistID { _ = await team.acquire(setlistID, takeover: false) } } }.disabled(setlistID == nil)
                    Button("다른 진행자의 권한을 넘겨받기") { takeover = true }.disabled(setlistID == nil)
                    Button("예배 안내 시작") { Task { if let setlistID { _ = await team.startSession(setlistID) } } }.disabled(!selectedHasLease)
                    if selectedIsLive { Text(selectedHasLease ? "이 iPad가 진행 중" : "안내 읽기 전용"); Button("예배 안내 종료") { Task { _ = await team.endSession() } }.disabled(!selectedHasLease) }
                }
                Section("안내할 곡 준비") {
                    Picker("예배 목록의 곡", selection: $itemID) {
                        Text("목록 밖의 곡 직접 선택").tag(nil as UUID?)
                        ForEach(team.items.filter { $0.value["setlist_id"].uuid == setlistID && $0.value["active"].flag }) { item in
                            Text(team.songTitle(item.value["song_id"].uuid ?? item.id)).tag(Optional(item.id))
                        }
                    }.onChange(of: itemID) { _ in
                        if let value = team.items.first(where: { $0.id == itemID })?.value { versionID = value["team_chart_version_id"].uuid; key = value["performance_key"].text ?? "" }
                    }
                    if itemID == nil {
                        Picker("팀 악보", selection: $versionID) {
                            Text("악보 선택").tag(nil as UUID?)
                            ForEach(team.versions) { version in Text("\(team.songTitle(version.value["song_id"].uuid ?? version.id)) · v\(version.value["version_number"].integer ?? 0)").tag(Optional(version.id)) }
                        }.onChange(of: versionID) { _ in key = team.versions.first { $0.id == versionID }?.value["written_key"].text ?? "" }
                    }
                    TextField("연주 키", text: $key).textInputAutocapitalization(.characters)
                    Text("곡을 고르는 동안 팀 화면은 바뀌지 않아요. 안내를 보내도 각 연주자가 직접 탭해야 열립니다.").font(.subheadline)
                    Button("이 곡 안내 보내기") { Task { if let versionID { _ = await team.announcePrepared(itemID: itemID, versionID: versionID, key: key) } } }
                        .disabled(!team.online || !selectedHasLease || !selectedIsLive || versionID == nil || !MusicalKey.isValid(key))
                }
                if selectedHasLease, selectedIsLive, team.live?.latest != nil {
                    Section("팀 메모") { Button("현재 안내의 정확한 팀 악보에 필기") { editor = true } }
                }
                if let error = team.error { Text(error).foregroundStyle(.orange) }
                Section("최근 안내") { ForEach(team.live?.history ?? [], id: \.id) { call in Text("\(team.songTitle(call.songID)) · \(call.performanceKey) · #\(call.sequence)") } }
            }.disabled(team.busy).navigationTitle("예배 진행")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("닫기") { dismiss() } } }
                .confirmationDialog("다른 iPad의 진행 권한을 종료하고 이 iPad로 넘겨받습니다.", isPresented: $takeover) {
                    Button("진행 권한 넘겨받기") { Task { if let setlistID { _ = await team.acquire(setlistID, takeover: true) } } }
                }
                .sheet(isPresented: $editor) { if let call = team.live?.latest { TeamInkSheet(team: team, call: call, editable: true) } }
        }
    }
}

struct SongCueBanner: View {
    @ObservedObject var team: TeamWorkspace
    let opened: () -> Void
    @State private var alternatives = false
    @State private var history = false
    var body: some View {
        HStack(spacing: 12) {
            if let call = team.pending {
                Image(systemName: "bell").foregroundStyle(StandStyle.blue).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(team.songTitle(call.songID)).font(.headline).lineLimit(1).minimumScaleFactor(0.7)
                    Text("연주 키 \(call.performanceKey) · \(team.online ? String(localized: "새 곡 안내") : String(localized: "마지막 수신 안내 · 오프라인"))").font(.caption).lineLimit(1).minimumScaleFactor(0.7)
                }.accessibilityElement(children: .combine)
                Spacer(minLength: 0)
                Button { Task { if await team.accept(call) { opened() } else { alternatives = true } } } label: {
                    ViewThatFits(in: .horizontal) {
                        Text("탭하여 열기").fixedSize(horizontal: true, vertical: false)
                        Text("열기").fixedSize(horizontal: true, vertical: false)
                    }
                }
                    .buttonStyle(.borderedProminent).font(.headline).dynamicTypeSize(...DynamicTypeSize.large)
                    .frame(minWidth: 70, minHeight: 44).disabled(team.busy).accessibilityLabel(Text("탭하여 열기"))
                    .accessibilityIdentifier("acceptSongCue")
                    .confirmationDialog("기본 악보를 열지 못했어요. 이번에만 다른 악보를 직접 선택할 수 있어요.", isPresented: $alternatives) {
                        ForEach(team.versionsForSong(call.songID)) { version in Button("v\(version.value["version_number"].integer ?? 0) · \(version.value["written_key"].text ?? "?") 이번에만 열기") {
                            Task { if await team.accept(call, explicitVersion: version.id) { opened() } }
                        } }
                        Button("취소", role: .cancel) {}
                    }
            } else {
                Image(systemName: team.session == nil ? "ipad" : (team.online ? "checkmark.icloud" : "icloud.slash")).foregroundStyle(.secondary).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(team.session == nil ? String(localized: "내 기기 악보 · 개인 메모") : (team.live?.ended == true ? String(localized: "이번 예배 진행이 종료됐어요") : (team.online ? String(localized: "새 곡 안내를 기다리고 있어요") : String(localized: "오프라인 · 검증된 기기 악보 사용"))))
                        .font(.subheadline).lineLimit(1).minimumScaleFactor(0.7)
                    if let checked = team.connectionCheckedAt, team.session != nil {
                        HStack(spacing: 4) { Text("마지막 팀 확인"); Text(checked, style: .time) }.font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    } else {
                        Text(team.session == nil ? String(localized: "페이지 이동과 필기는 이 기기에 저장돼요") : String(localized: "팀 최신 자료는 연결 후 직접 확인해 주세요"))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
                    }
                }.accessibilityElement(children: .combine)
                Spacer(minLength: 0)
            }
            if team.live != nil {
                Button { history = true } label: { Image(systemName: "clock").frame(width: 44, height: 44) }.accessibilityLabel(Text("최근 안내"))
            }
        }.padding(.horizontal, 12).frame(height: 76)
            .background(team.pending == nil ? Color.secondary.opacity(0.04) : StandStyle.blue.opacity(0.08))
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .accessibilityIdentifier("songCueStatus")
            .sheet(isPresented: $history) { NavigationStack { List(team.live?.history ?? [], id: \.id) { call in Text("\(team.songTitle(call.songID)) · \(call.performanceKey) · #\(call.sequence)") }.navigationTitle("최근 안내").toolbar { Button("닫기") { history = false } } } }
    }
}
