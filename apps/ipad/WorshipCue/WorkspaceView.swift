import SwiftUI
import WorshipCueLocal
import WorshipCueCore
import UniformTypeIdentifiers

private enum WorkspacePanel: Identifiable {
    case song(UUID), setlist(LocalSetlist)
    var id: UUID { switch self { case .song(let id): return id; case .setlist(let set): return set.id } }
}
private struct ImportSource: Identifiable { let id = UUID(); let url: URL }

struct WorkspaceView: View {
    @ObservedObject var stand: MusicStand
    @Environment(\.dismiss) private var dismiss
    @Binding var tab: Int
    var embedded = false
    var onOpen: (() -> Void)?
    @State private var query = ""
    @State private var favorites = false
    @State private var panel: WorkspacePanel?
    @State private var importing = false
    @State private var importSource: ImportSource?
    @FocusState private var searchFocused: Bool

    init(stand: MusicStand, tab: Binding<Int>, embedded: Bool = false, onOpen: (() -> Void)? = nil) {
        self.stand = stand; _tab = tab; self.embedded = embedded; self.onOpen = onOpen
    }
    private func returnToReader() { if let onOpen { onOpen() } else { dismiss() } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !embedded {
                    Picker("작업 공간", selection: $tab) {
                        Text("오늘").tag(0); Text("라이브러리").tag(1)
                    }.pickerStyle(.segmented).padding().accessibilityIdentifier("workspaceTab")
                }
                if tab == 0 { today } else { songLibrary }
            }
            .navigationTitle(tab == 0 ? "예배 준비" : "곡 라이브러리")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: tab) { _ in searchFocused = false }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("악보로 돌아가기") { returnToReader() }.accessibilityIdentifier("closeWorkspace") }
                ToolbarItem(placement: .primaryAction) {
                    if tab == 0 {
                        Button { panel = .setlist(LocalSetlist(title: String(localized: "주일 예배"))) } label: { Label("예배 목록 만들기", systemImage: "plus") }
                            .accessibilityIdentifier("newSetlist")
                    } else {
                        Button { importing = true } label: { Label("PDF 가져오기", systemImage: "plus") }.accessibilityIdentifier("libraryImport")
                    }
                }
            }
            .sheet(item: $panel) { panel in
                switch panel {
                case .song(let id): SongDetailSheet(stand: stand, songID: id, onOpen: { returnToReader() })
                case .setlist(let draft): SetlistEditor(stand: stand, initial: draft, onOpen: { returnToReader() })
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf]) { result in
                switch result {
                case .success(let url): importSource = ImportSource(url: url)
                case .failure: stand.error = String(localized: "파일 선택을 완료하지 못했어요.")
                }
            }
            .sheet(item: $importSource) { ImportChartSheet(stand: stand, url: $0.url) }
            .workspaceError(stand)
        }
    }

    private var today: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("나의 예배 준비").font(.largeTitle).fontWeight(.semibold)
                    Text("이번 예배의 악보와 메모를 편안하게 준비하세요.").font(.subheadline).foregroundStyle(.secondary)
                }
                if let chart = stand.current {
                    Button { returnToReader() } label: {
                        HStack(spacing: 18) {
                            ChartThumbnail(stand: stand, versionID: chart.id, page: stand.pageIndex)
                            VStack(alignment: .leading, spacing: 6) {
                                Text("이어서 보기").font(.caption).foregroundStyle(.secondary)
                                Text(stand.currentSongTitle ?? chart.name).font(.title3).fontWeight(.semibold).lineLimit(2)
                                Text("마지막 페이지 \(stand.pageIndex + 1)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "arrow.up.right").font(.title3).foregroundStyle(StandStyle.blue)
                        }.padding(20).frame(maxWidth: .infinity, minHeight: 110, alignment: .leading)
                            .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 18))
                    }.buttonStyle(.plain).accessibilityIdentifier("resumeChart")
                }
                HStack {
                    Text("예배 목록").font(.title2).fontWeight(.semibold)
                    Spacer()
                    Label("이 iPad에 저장", systemImage: "ipad").font(.caption).foregroundStyle(.secondary)
                }
                if stand.library.setlists.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "music.note.list").font(.largeTitle).foregroundStyle(StandStyle.blue)
                        Text("이번 예배를 준비해 보세요").font(.headline)
                        Text("순서대로 부를 곡과 대기곡을 함께 담고, 곡마다 사용할 악보와 연주 키를 정하세요.").foregroundStyle(.secondary)
                        Button { panel = .setlist(LocalSetlist(title: String(localized: "주일 예배"))) } label: {
                            Label("예배 목록 만들기", systemImage: "plus").frame(minHeight: 44)
                        }.buttonStyle(.borderedProminent).accessibilityIdentifier("emptyNewSetlist")
                    }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 18))
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 16)], spacing: 16) {
                    ForEach(stand.library.setlists) { set in
                        Button { panel = .setlist(set) } label: {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Image(systemName: "calendar").foregroundStyle(StandStyle.blue)
                                    Text(set.serviceDate, style: .date).font(.subheadline).foregroundStyle(.secondary)
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                                }
                                Text(set.title).font(.title3).fontWeight(.semibold).lineLimit(2)
                                Text("예정곡 \(set.items.filter { $0.section == .planned }.count) · 대기곡 \(set.items.filter { $0.section == .standby }.count)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(20).frame(maxWidth: .infinity, minHeight: 144, alignment: .leading)
                                .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 18))
                        }.buttonStyle(.plain).accessibilityIdentifier("setlist.\(set.id.uuidString)")
                    }
                }
            }.padding(24)
        }.background(StandStyle.surface)
    }
    private var songLibrary: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("곡 제목 · 초성 · 별칭 · 찬송가 번호", text: $query)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("librarySearch")
                        .focused($searchFocused).submitLabel(.search).onSubmit { searchFocused = false }
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44) }
                            .accessibilityLabel(Text("검색어 지우기"))
                    }
                }.padding(.horizontal, 14).frame(minHeight: 56).background(StandStyle.surface, in: RoundedRectangle(cornerRadius: 14))
                Toggle(isOn: $favorites) { Image(systemName: favorites ? "star.fill" : "star").frame(width: 44, height: 44) }
                    .toggleStyle(.button).accessibilityLabel(Text("즐겨찾기")).accessibilityIdentifier("favoritesOnly")
            }.padding(20)
            let results = stand.library.search(query, favoritesOnly: favorites)
            ScrollView {
                LazyVStack(spacing: 10) {
                    if results.isEmpty { Text("검색 결과가 없어요. PDF를 가져오거나 검색어를 바꿔 주세요.").foregroundStyle(.secondary).padding(24) }
                    ForEach(results) { song in
                        Button { searchFocused = false; panel = .song(song.id) } label: {
                            HStack(spacing: 16) {
                                if let version = stand.library.versions(for: song.id).last {
                                    ChartThumbnail(stand: stand, versionID: version.id)
                                }
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(song.title).font(.headline).lineLimit(2)
                                        if song.favorite { Image(systemName: "star.fill").font(.caption).foregroundStyle(StandStyle.blue) }
                                    }
                                    Text("악보 \(stand.library.versions(for: song.id).count)개").font(.caption).foregroundStyle(.secondary)
                                    if let number = song.hymnNumber { Text("\(song.hymnEdition ?? "") \(number)장").font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                            }.padding(16).frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
                                .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 16))
                        }.buttonStyle(.plain).accessibilityIdentifier("song.\(song.id.uuidString)")
                    }
                }.padding(.horizontal, 20).padding(.bottom, 20)
            }.background(StandStyle.surface)
        }
    }

}

struct SongDetailSheet: View {
    @ObservedObject var stand: MusicStand
    let songID: UUID
    var onOpen: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var importing = false
    @State private var source: ImportSource?
    @State private var packet: LocalChart?
    private var song: LibrarySong? { stand.library.songs.first { $0.id == songID } }
    var body: some View {
        NavigationStack {
            List {
                if let song {
                    Section {
                        Text(song.title).font(.title2).textSelection(.enabled)
                        if !song.aliases.isEmpty { Text(song.aliases.joined(separator: " · ")).foregroundStyle(.secondary) }
                        HStack {
                            Button {
                                var updated = song; updated.favorite.toggle(); stand.updateSong(updated)
                            } label: {
                                Label(song.favorite ? String(localized: "즐겨찾기 해제") : String(localized: "즐겨찾기 추가"),
                                      systemImage: song.favorite ? "star.fill" : "star")
                                    .frame(minHeight: 44)
                            }.accessibilityIdentifier("toggleFavorite")
                            Spacer(); Button { editing = true } label: { Text("곡 정보 수정").frame(minHeight: 44) }
                                .accessibilityIdentifier("editSong")
                        }.frame(minHeight: 44)
                    }
                    Section("악보 버전") {
                        Text("열기는 현재 악보만 바꿉니다. 개인 기본 악보는 별도로 지정하세요. 새 버전에 메모가 자동으로 옮겨지지 않습니다.")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(stand.library.versions(for: songID)) { version in
                            VStack(alignment: .leading, spacing: 8) {
                                VersionHeading(version: version, preferred: stand.library.preferences[songID] == version.id)
                                if let first = version.sourceFirstPage, let last = version.sourceLastPage {
                                    Text("주간 PDF \(first)–\(last)쪽에서 가져옴").font(.caption).foregroundStyle(.secondary)
                                }
                                HStack {
                                    Button { Task { if await stand.openVersion(version.id) { dismiss(); onOpen() } } } label: {
                                        Text("열기").frame(minWidth: 44, minHeight: 44)
                                    }.buttonStyle(.bordered)
                                        .accessibilityIdentifier("openVersion.\(version.number)")
                                    Spacer()
                                    Button { stand.prefer(version) } label: { Text("개인 기본 악보로 지정").frame(minHeight: 44) }
                                        .buttonStyle(.bordered)
                                        .disabled(stand.library.preferences[songID] == version.id)
                                        .accessibilityIdentifier("preferVersion.\(version.number)")
                                    Menu {
                                        Button("주간 PDF에서 곡 나누기") { packet = stand.charts.first { $0.id == version.id } }
                                    } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }
                                    .accessibilityLabel(Text("악보 작업"))
                                }.frame(minHeight: 44).buttonStyle(.borderless)
                            }.padding(.vertical, 8)
                        }
                        Button("새 PDF 버전 가져오기") { importing = true }.frame(minHeight: 44).accessibilityIdentifier("newVersion")
                    }
                }
            }.buttonStyle(.borderless).navigationTitle("곡 · 악보")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } } }
                .disabled(stand.busy).scrollDismissesKeyboard(.interactively)
                .sheet(isPresented: $editing) { if let song { SongMetadataSheet(stand: stand, initial: song) } }
                .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf]) { result in
                    switch result {
                    case .success(let url): source = ImportSource(url: url)
                    case .failure: stand.error = String(localized: "파일 선택을 완료하지 못했어요.")
                    }
                }
                .sheet(item: $source) { ImportChartSheet(stand: stand, url: $0.url, initialSongID: songID) }
                .sheet(item: $packet) { PacketImportSheet(stand: stand, chart: $0) }
                .workspaceError(stand)
        }
    }
}

struct VersionHeading: View {
    let version: LibraryVersion
    var preferred = false
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("v\(version.number)").font(.headline).monospacedDigit()
                Text(version.writtenKey ?? String(localized: "악보 키 미상")).font(.subheadline)
                if preferred { Label("개인 기본", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.teal) }
            }
            Text(version.label).lineLimit(2)
        }
    }
}

struct SongMetadataSheet: View {
    @ObservedObject var stand: MusicStand
    let initial: LibrarySong
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var aliases: String
    @State private var hymn: String
    @State private var edition: String
    init(stand: MusicStand, initial: LibrarySong) {
        self.stand = stand; self.initial = initial
        _title = State(initialValue: initial.title); _aliases = State(initialValue: initial.aliases.joined(separator: "\n"))
        _hymn = State(initialValue: initial.hymnNumber.map(String.init) ?? ""); _edition = State(initialValue: initial.hymnEdition ?? "")
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("검색 정보") {
                    TextField("곡 제목", text: $title).accessibilityIdentifier("songTitle")
                    TextField("별칭 · 한 줄에 하나", text: $aliases, axis: .vertical).lineLimit(2...5).accessibilityIdentifier("songAliases")
                }
                Section("찬송가 · 선택 사항") {
                    TextField("번호", text: $hymn).keyboardType(.numberPad)
                    TextField("판본 · 예: 새찬송가", text: $edition)
                    Text("찬송가 번호와 판본은 함께 입력해 주세요.").font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle("곡 정보")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("저장") {
                        var song = initial; song.title = title.trimmed; song.aliases = aliases.split(separator: "\n").map { String($0).trimmed }.filter { !$0.isEmpty }
                        song.hymnNumber = hymn.trimmed.isEmpty ? nil : Int(hymn.trimmed)
                        song.hymnEdition = edition.trimmed.isEmpty ? nil : edition.trimmed
                        guard hymn.trimmed.isEmpty || Int(hymn.trimmed) != nil else {
                            stand.error = String(localized: "찬송가 번호를 숫자로 입력해 주세요."); return
                        }
                        if stand.updateSong(song) { dismiss() }
                    }.accessibilityIdentifier("saveSong") }
                }.workspaceError(stand)
        }
    }
}

extension String { var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping } }
private struct WorkspaceError: ViewModifier {
    @ObservedObject var stand: MusicStand
    func body(content: Content) -> some View {
        content.alert("확인 필요", isPresented: Binding(get: { stand.error != nil }, set: { if !$0 { stand.error = nil } })) {
            Button("닫기", role: .cancel) { stand.error = nil }
        } message: { Text(stand.error ?? "") }
    }
}
extension View { func workspaceError(_ stand: MusicStand) -> some View { modifier(WorkspaceError(stand: stand)) } }
