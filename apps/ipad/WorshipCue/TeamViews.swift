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

    var body: some View {
        NavigationStack {
            Form {
                if let error = team.error {
                    Section { Text(error).foregroundStyle(.orange); Button("닫기") { team.error = nil } }
                }
                if !team.configured {
                    Section {
                        Label("팀 연결 준비 중", systemImage: "person.2")
                        Text("이 기기의 악보·필기·예배 목록을 계속 사용할 수 있어요. 팀 연결은 개발용 서버가 준비되면 사용할 수 있습니다.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                } else if team.session == nil {
                    Section("팀 계정") {
                        TextField("이메일", text: $email).textInputAutocapitalization(.never).keyboardType(.emailAddress).autocorrectionDisabled()
                            .accessibilityIdentifier("teamEmail")
                        if codeSent {
                            TextField("인증 번호", text: $code).keyboardType(.numberPad).textContentType(.oneTimeCode).accessibilityIdentifier("teamCode")
                            Button("로그인") { Task { if await team.signIn(email, code: code) { await reloadSessions() } } }.disabled(code.count < 6)
                        }
                        Button(codeSent ? "인증 번호 다시 받기" : "인증 번호 받기") { Task { codeSent = await team.sendCode(email) } }
                            .disabled(email.isEmpty).accessibilityIdentifier("sendTeamCode")
                    }
                    Section("게스트 초대") {
                        TextField("초대 코드", text: $invitation).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("초대한 예배에 참여") { Task { if await team.redeem(invitation, guest: true) { await reloadSessions() } } }.disabled(invitation.isEmpty)
                        Text("게스트는 초대받은 예배의 자료만 볼 수 있어요. 개인 메모는 이 기기에 저장됩니다.").font(.caption)
                    }
                } else {
                    Section {
                        Label(team.message, systemImage: team.online ? "checkmark.icloud" : "icloud.slash")
                        Button("팀 자료 새로 확인") { Task { await team.refresh(); await reloadSessions() } }
                        Button("내 기기 악보로 돌아가기") { Task { if await team.useLocalReader() { opened(); dismiss() } } }
                    }
                    if !team.memberships.isEmpty {
                        Section("내 팀") {
                            ForEach(Array(team.memberships.enumerated()), id: \.offset) { _, membership in
                                Button { Task { await team.chooseWorkspace(membership); await reloadSessions() } } label: {
                                    HStack {
                                        Text(membership["role"].text == "admin" ? "내 교회 · 관리자" : "초대받은 팀")
                                        Spacer()
                                        if membership["church_id"].uuid == team.selectedChurch { Image(systemName: "checkmark") }
                                    }
                                }
                            }
                        }
                    }
                    if !team.session!.anonymous {
                        Section("교회·팀 만들기") {
                            TextField("교회 이름", text: $workspaceName)
                            Button("새 비공개 교회·팀 만들기") { Task { _ = await team.createWorkspace(workspaceName) } }.disabled(workspaceName.isEmpty)
                        }
                    }
                    Section("초대 코드로 참여") {
                        TextField("초대 코드", text: $invitation).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("참여") { Task { _ = await team.redeem(invitation, guest: false); await reloadSessions() } }.disabled(invitation.isEmpty)
                    }
                    Section("진행 중인 예배") {
                        if sessions.isEmpty { Text("진행 중인 예배가 없어요.").foregroundStyle(.secondary) }
                        ForEach(sessions.filter { $0.value["status"].text == "LIVE" }) { session in
                            Button("\(team.setlists.first { $0.id == session.value["setlist_id"].uuid }?.value["title"].text ?? String(localized: "예배")) · 안내 받기") {
                                Task { if await team.joinSession(session.id) { dismiss() } }
                            }
                        }
                    }
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
                    Section("예배 준비") {
                        ForEach(team.setlists) { setlist in
                            Button { Task { _ = await team.prepare(setlist) } } label: {
                                Label("\(setlist.value["title"].text ?? "") · 오프라인 악보 준비", systemImage: "arrow.down.doc")
                            }
                        }
                        Text("다운로드 후 PDF와 현재 팀 메모의 내용·페이지·크기를 확인합니다. 페이지 이동은 다른 기기에 전달하지 않습니다.").font(.caption)
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
                    }
                    Section { Button("로그아웃", role: .destructive) { Task { _ = await team.logout() } } }
                }
            }.disabled(team.busy)
                .navigationTitle("팀 작업 공간")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("닫기") { dismiss() }.frame(minHeight: 44) } }
                .task { await reloadSessions() }
                .onChange(of: team.scopeID) { _ in sessions = []; Task { await reloadSessions() } }
                .sheet(isPresented: $publishSheet) { TeamPublishSheet(team: team, local: local) }
                .sheet(isPresented: $setlistSheet) { TeamSetlistSheet(team: team) }
                .sheet(isPresented: $controllerSheet) { TeamControllerSheet(team: team) }
                .sheet(isPresented: $team.showConflicts) { PersonalConflictSheet(team: team) }
        }.preferredColorScheme(.light)
    }
    private func reloadSessions() async {
        let captured = team.scopeID, values = await team.sessions()
        guard captured == team.scopeID else { return }
        sessions = values
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
        if let call = team.pending {
            HStack(spacing: 12) {
                Image(systemName: "bell").foregroundStyle(StandStyle.blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text(team.songTitle(call.songID)).font(.headline)
                    Text("연주 키 \(call.performanceKey) · \(team.online ? String(localized: "새 곡 안내") : String(localized: "마지막 수신 안내 · 오프라인"))").font(.caption)
                }
                Spacer()
                Button("탭하여 열기") { Task { if await team.accept(call) { opened() } else { alternatives = true } } }
                    .buttonStyle(.borderedProminent).frame(minHeight: 44).disabled(team.busy).accessibilityIdentifier("acceptSongCue")
                Button { history = true } label: { Image(systemName: "clock").frame(width: 44, height: 44) }.accessibilityLabel(Text("최근 안내"))
            }.padding(12).background(StandStyle.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 10)
                .confirmationDialog("기본 악보를 열지 못했어요. 이번에만 다른 악보를 직접 선택할 수 있어요.", isPresented: $alternatives) {
                    ForEach(team.versionsForSong(call.songID)) { version in Button("v\(version.value["version_number"].integer ?? 0) · \(version.value["written_key"].text ?? "?") 이번에만 열기") {
                        Task { if await team.accept(call, explicitVersion: version.id) { opened() } }
                    } }
                    Button("취소", role: .cancel) {}
                }
                .sheet(isPresented: $history) { NavigationStack { List(team.live?.history ?? [], id: \.id) { call in Text("\(team.songTitle(call.songID)) · \(call.performanceKey) · #\(call.sequence)") }.navigationTitle("최근 안내").toolbar { Button("닫기") { history = false } } } }
        }
    }
}
