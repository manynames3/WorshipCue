import SwiftUI
import WorshipCueCore

/// Browsing a workspace never selects a chart or acknowledges a live cue.
struct TeamBrowserView: View {
    @ObservedObject var team: TeamWorkspace
    let section: StandSection
    let connect: () -> Void
    let opened: () -> Void
    @State private var query = ""
    @State private var editingSetlists = false

    private var matchingSongs: [TeamRow] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return team.songs }
        return team.songs.compactMap { song -> (TeamRow, Int)? in
            guard let score = KoreanSearch.score(query: query, title: team.songTitle(song.id),
                                                aliases: song.value["aliases"].list.compactMap(\.text)) else { return nil }
            return (song, score)
        }.sorted { $0.1 < $1.1 }.map(\.0)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(section == .today ? String(localized: "함께 준비하는 예배") : String(localized: "우리 팀 악보"))
                            .font(.largeTitle.weight(.semibold))
                        Text(team.selectedChurchName).font(.subheadline).foregroundStyle(.secondary)
                        HStack {
                            Label(team.selectedWorkspaceName, systemImage: "person.2")
                            Spacer()
                            Text(team.selectedRoleLabel).font(.caption)
                        }.font(.headline)
                    }
                    if team.session == nil || team.selectedTeam == nil {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("팀을 선택하면 이 팀의 악보·예배 목록·대화를 볼 수 있어요.")
                            Button("팀에 참여하거나 새 팀 만들기", action: connect)
                                .buttonStyle(.borderedProminent).frame(minHeight: 44)
                            Text("내 기기의 악보와 메모는 그대로 유지됩니다.").font(.caption).foregroundStyle(.secondary)
                        }.padding(20).background(StandStyle.surface, in: RoundedRectangle(cornerRadius: 16))
                    } else {
                        if !team.online {
                            Label("저장된 팀 자료를 보고 있어요. 최신 팀 메모는 연결 후 다시 확인해 주세요.", systemImage: "icloud.slash")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        if team.error != nil {
                            Button("팀 연결·권한 확인", action: connect).frame(minHeight: 44)
                        }
                        if section == .today { preparation } else { library }
                    }
                }.padding(24)
            }
            .background(StandStyle.surface.opacity(0.4))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("악보로 돌아가기", action: opened).accessibilityIdentifier("closeTeamBrowser")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("팀 선택", action: connect).accessibilityIdentifier("chooseTeamBrowserWorkspace")
                }
            }
            .refreshable { await team.refresh() }
            .sheet(isPresented: $editingSetlists) { TeamSetlistSheet(team: team) }
            .accessibilityIdentifier("teamBrowser")
        }
    }

    private var preparation: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let chart = team.reader?.current {
                Button(action: opened) {
                    HStack {
                        Image(systemName: "music.note.list").font(.title2)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("이어서 보기").font(.caption)
                            Text(team.reader?.currentSongTitle ?? chart.name).font(.headline)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                    }.padding(18).background(StandStyle.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                }.buttonStyle(.plain).accessibilityIdentifier("resumeTeamChart")
            }
            if team.setlists.isEmpty {
                Text("아직 준비한 팀 예배 목록이 없어요.").foregroundStyle(.secondary)
            }
            ForEach(team.setlists) { setlist in
                VStack(alignment: .leading, spacing: 14) {
                    Text(setlist.value["title"].text ?? "").font(.title3.weight(.semibold))
                    TeamPreparationChecklist(team: team, setlist: setlist)
                    DisclosureGroup("예배 순서·예비곡") {
                        let items = team.items.filter { $0.value["setlist_id"].uuid == setlist.id && $0.value["active"].flag }
                            .sorted { ($0.value["position"].integer ?? 0) < ($1.value["position"].integer ?? 0) }
                        ForEach(items) { item in
                            if let song = item.value["song_id"].uuid, let chart = item.value["team_chart_version_id"].uuid {
                                Button {
                                    let version = team.preferredVersions[song] ?? chart
                                    Task { if await team.openPreparedItem(item.id, versionID: version) { opened() } }
                                } label: {
                                    HStack {
                                        Text(team.songTitle(song)).lineLimit(2)
                                        Spacer()
                                        if item.value["kind"].text == "standby" { Text("예비곡").font(.caption) }
                                        Text(item.value["performance_key"].text ?? "").font(.subheadline).monospaced()
                                        Image(systemName: "chevron.right").font(.caption)
                                    }.frame(minHeight: 44)
                                }.buttonStyle(.plain).disabled(team.busy)
                                    .accessibilityIdentifier("openPreparedItem.\(item.id)")
                            }
                        }
                    }
                }.padding(20).background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 16))
            }
            if team.canLead {
                Button("팀 예배 목록 만들기·수정") { editingSetlists = true }
                    .buttonStyle(.bordered).frame(minHeight: 44)
            }
        }
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("곡 제목 · 초성 · 별칭", text: $query).autocorrectionDisabled().textInputAutocapitalization(.never)
                    .accessibilityIdentifier("teamLibrarySearch")
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44) }
                        .accessibilityLabel(Text("검색 지우기"))
                }
            }.padding(.horizontal, 16).frame(minHeight: 52)
                .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 14))
            if matchingSongs.isEmpty { Text("표시할 팀 악보가 없어요.").foregroundStyle(.secondary) }
            ForEach(matchingSongs) { song in
                VStack(alignment: .leading, spacing: 10) {
                    Text(team.songTitle(song.id)).font(.title3.weight(.semibold))
                    ForEach(team.versionsForSong(song.id)) { version in
                        HStack(spacing: 12) {
                            Button {
                                Task { if await team.openVersion(version.id) { opened() } }
                            } label: {
                                HStack {
                                    Image(systemName: "doc.richtext")
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(version.value["label"].text ?? "").lineLimit(2)
                                        Text("v\(version.value["version_number"].integer ?? 0) · \(version.value["written_key"].text ?? "?")")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption)
                                }.frame(minHeight: 52).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityIdentifier("openTeamVersion.\(version.id)")
                            Button { Task { await team.prefer(version.id) } } label: {
                                Image(systemName: team.preferredVersions[song.id] == version.id ? "star.fill" : "star")
                                    .frame(width: 44, height: 44)
                            }.buttonStyle(.plain).accessibilityLabel(Text("내 기본 악보로 지정"))
                                .accessibilityValue(team.preferredVersions[song.id] == version.id ? Text("선택됨") : Text(""))
                        }.disabled(team.busy)
                    }
                }.padding(20).background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }
}
