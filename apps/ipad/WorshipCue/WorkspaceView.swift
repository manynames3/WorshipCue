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
    @State private var tab = 0
    @State private var query = ""
    @State private var favorites = false
    @State private var panel: WorkspacePanel?
    @State private var importing = false
    @State private var importSource: ImportSource?
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("작업 공간", selection: $tab) {
                    Text("오늘").tag(0); Text("라이브러리").tag(1)
                }.pickerStyle(.segmented).padding().accessibilityIdentifier("workspaceTab")
                if tab == 0 { today } else { songLibrary }
            }
            .navigationTitle("WorshipCue")
            .onChange(of: tab) { _ in searchFocused = false }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("악보로 돌아가기") { dismiss() }.accessibilityIdentifier("closeWorkspace") }
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
                case .song(let id): SongDetailSheet(stand: stand, songID: id, onOpen: { dismiss() })
                case .setlist(let draft): SetlistEditor(stand: stand, initial: draft, onOpen: { dismiss() })
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
        List {
            Section {
                if let chart = stand.current {
                    Button { dismiss() } label: {
                        Label { VStack(alignment: .leading, spacing: 5) {
                            Text("이어서 보기").font(.headline)
                            Text(chart.name).lineLimit(2)
                            Text("마지막 페이지 \(stand.pageIndex + 1)").font(.caption).foregroundStyle(.secondary)
                        } } icon: { Image(systemName: "book") }
                        .frame(minHeight: 56)
                    }
                }
                Text("이 iPad에 저장하는 개인 작업 공간입니다. 예배 목록과 기본 악보를 준비한 뒤 PDF로 백업할 수 있습니다.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Section("예배 목록") {
                if stand.library.setlists.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("이번 예배를 준비해 보세요").font(.headline)
                        Text("순서대로 부를 곡과 대기곡을 함께 담고, 곡마다 사용할 악보와 연주 키를 정하세요.").foregroundStyle(.secondary)
                    }.padding(.vertical, 12)
                }
                ForEach(stand.library.setlists) { set in
                    Button { panel = .setlist(set) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(set.title).font(.headline).lineLimit(2)
                            Text(set.serviceDate, style: .date).font(.subheadline)
                            Text("예정곡 \(set.items.filter { $0.section == .planned }.count) · 대기곡 \(set.items.filter { $0.section == .standby }.count)")
                                .font(.caption).foregroundStyle(.secondary)
                        }.frame(minHeight: 56)
                    }.accessibilityIdentifier("setlist.\(set.id.uuidString)")
                }
            }
        }
    }
    private var songLibrary: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("곡 제목 · 초성 · 별칭 · 찬송가 번호", text: $query)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("librarySearch")
                    .focused($searchFocused).submitLabel(.search).onSubmit { searchFocused = false }
                Toggle("즐겨찾기", isOn: $favorites).toggleStyle(.button).accessibilityIdentifier("favoritesOnly")
            }.padding(.horizontal).frame(minHeight: 56)
            let results = stand.library.search(query, favoritesOnly: favorites)
            List {
                if results.isEmpty { Text("검색 결과가 없어요. PDF를 가져오거나 검색어를 바꿔 주세요.").foregroundStyle(.secondary) }
                ForEach(results) { song in
                    Button { searchFocused = false; panel = .song(song.id) } label: {
                        HStack {
                            Image(systemName: song.favorite ? "star.fill" : "music.note").foregroundStyle(.teal)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(song.title).font(.headline).lineLimit(2)
                                Text("악보 \(stand.library.versions(for: song.id).count)개").font(.caption).foregroundStyle(.secondary)
                                if let number = song.hymnNumber { Text("\(song.hymnEdition ?? "") \(number)장").font(.caption) }
                            }
                            Spacer(); Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }.frame(minHeight: 56)
                    }.accessibilityIdentifier("song.\(song.id.uuidString)")
                }
            }
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
