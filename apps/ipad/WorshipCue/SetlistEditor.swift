import SwiftUI
import WorshipCueLocal
import WorshipCueCore

private struct AddSongTarget: Identifiable { let section: SetlistSection; var id: String { section.rawValue } }

struct SetlistEditor: View {
    @ObservedObject var stand: MusicStand
    var onOpen: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: LocalSetlist
    @State private var adding: AddSongTarget?
    @State private var editingItem: SetlistItem?
    @FocusState private var titleFocused: Bool
    init(stand: MusicStand, initial: LocalSetlist, onOpen: @escaping () -> Void) {
        self.stand = stand; self.onOpen = onOpen; _draft = State(initialValue: initial)
    }
    var body: some View {
        NavigationStack {
            List {
                Section("예배 정보") {
                    TextField("예배 이름", text: $draft.title).accessibilityIdentifier("setlistTitle").focused($titleFocused)
                        .submitLabel(.done).onSubmit { titleFocused = false }
                    DatePicker("예배 날짜", selection: $draft.serviceDate, displayedComponents: .date)
                    Text("\(draft.timeZoneID) · 이 iPad에 저장").font(.caption).foregroundStyle(.secondary)
                }
                itemsSection(.planned)
                itemsSection(.standby)
                Section {
                    Button { Task {
                        titleFocused = false
                        if let saved = stand.saveSetlist(draft) { draft = saved; await stand.prepare(saved) }
                    } } label: { Label("저장하고 오프라인 파일 확인", systemImage: "checkmark.shield") }
                        .frame(minHeight: 56).accessibilityIdentifier("prepareSetlist")
                    if let report = stand.preparationReport {
                        Text(report).font(.subheadline).accessibilityIdentifier("preparationReport")
                    }
                    Text("파일 검사는 선택한 버전·개인 기본 악보·대기곡을 모두 확인합니다. 연주 키 표시는 PDF를 조옮김하지 않습니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle("예배 준비").scrollDismissesKeyboard(.interactively)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() }.accessibilityIdentifier("cancelSetlist") }
                    ToolbarItemGroup(placement: .primaryAction) {
                        EditButton().accessibilityIdentifier("reorderSetlist")
                        Menu {
                            Button("새 예배 목록으로 복사") {
                                titleFocused = false
                                if let cloned = stand.saveSetlist(draft.clone(title: draft.title + String(localized: " 복사"))) { draft = cloned }
                            }.accessibilityIdentifier("cloneSetlist")
                        } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel(Text("예배 목록 작업"))
                            .accessibilityIdentifier("setlistActions")
                        Button("저장") { titleFocused = false; if stand.saveSetlist(draft) != nil { dismiss() } }.accessibilityIdentifier("saveSetlist")
                    }
                }
                .disabled(stand.busy)
                .sheet(item: $adding) { target in
                    AddSetlistSongSheet(stand: stand, section: target.section) { item in draft.items.append(item) }
                }
                .sheet(item: $editingItem) { item in
                    SetlistItemSheet(stand: stand, initial: item) { updated in
                        if let index = draft.items.firstIndex(where: { $0.id == updated.id }) { draft.items[index] = updated }
                    }
                }
                .workspaceError(stand)
        }
    }

    private func itemsSection(_ section: SetlistSection) -> some View {
        let items = draft.items.filter { $0.section == section }
        return Section {
            if items.isEmpty { Text(section == .planned ? "예정곡을 순서대로 추가해 주세요." : "예배 중 꺼낼 대기곡을 추가해 주세요.").foregroundStyle(.secondary) }
            ForEach(items) { item in
                SetlistRow(stand: stand, item: item, edit: { titleFocused = false; editingItem = item }, open: {
                    titleFocused = false
                    Task {
                        if let saved = stand.saveSetlist(draft) {
                            draft = saved
                            if await stand.openVersion(item.versionID) { dismiss(); onOpen() }
                        }
                    }
                }, duplicate: {
                    titleFocused = false
                    let duplicate = SetlistItem(songID: item.songID, versionID: item.versionID,
                        performanceKey: item.performanceKey, section: item.section)
                    if let index = draft.items.firstIndex(where: { $0.id == item.id }) { draft.items.insert(duplicate, at: index + 1) }
                })
            }
            .onDelete { offsets in
                let ids = Set(offsets.map { items[$0].id }); draft.items.removeAll { ids.contains($0.id) }
            }
            .onMove { offsets, target in
                var reordered = items; reordered.move(fromOffsets: offsets, toOffset: target)
                let others = draft.items.filter { $0.section != section }
                draft.items = section == .planned ? reordered + others : others + reordered
            }
            Button { titleFocused = false; adding = AddSongTarget(section: section) } label: {
                Label(section == .planned ? String(localized: "예정곡 추가") : String(localized: "대기곡 추가"), systemImage: "plus")
            }.frame(minHeight: 44).accessibilityIdentifier(section == .planned ? "addPlannedSong" : "addStandbySong")
        } header: { Text(section == .planned ? "예정곡" : "대기곡") }
    }
}

private struct SetlistRow: View {
    @ObservedObject var stand: MusicStand
    let item: SetlistItem
    let edit: () -> Void
    let open: () -> Void
    let duplicate: () -> Void
    var body: some View {
        let song = stand.library.songs.first { $0.id == item.songID }
        let version = stand.library.versions.first { $0.id == item.versionID }
        return HStack(spacing: 12) {
            Button(action: edit) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(song?.title ?? String(localized: "곡 정보 확인 필요")).font(.headline).lineLimit(2)
                    if let version {
                        Text("v\(version.number) · 악보 키 \(version.writtenKey ?? "?") · 연주 키 \(item.performanceKey ?? "?")")
                            .font(.caption).foregroundStyle(.secondary)
                        if let key = item.performanceKey, MusicalKey.compare(written: version.writtenKey, performance: key) != .matching {
                            Label(version.writtenKey == nil ? String(localized: "악보 키 확인 필요") : String(localized: "악보와 연주 키가 다릅니다"),
                                  systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                        }
                    }
                }.frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            }.buttonStyle(.plain).accessibilityIdentifier("editItem.\(item.id.uuidString)")
            Button(action: open) { Text("저장 후 열기").frame(minHeight: 56) }
                .buttonStyle(.borderless).accessibilityIdentifier("openSetlistItem.\(item.id.uuidString)")
            Menu { Button("같은 곡 한 번 더 추가", action: duplicate) } label: {
                Image(systemName: "ellipsis.circle").frame(width: 44, height: 44)
            }.accessibilityLabel(Text("곡 순서 작업")).accessibilityIdentifier("itemActions.\(item.id.uuidString)")
        }.buttonStyle(.borderless)
    }
}

struct AddSetlistSongSheet: View {
    @ObservedObject var stand: MusicStand
    let section: SetlistSection
    let added: (SetlistItem) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    var body: some View {
        NavigationStack {
            List {
                TextField("곡 제목 · 초성 · 별칭", text: $query).accessibilityIdentifier("setlistSongSearch")
                ForEach(stand.library.search(query)) { song in
                    Section(song.title) {
                        ForEach(stand.library.versions(for: song.id)) { version in
                            Button {
                                added(SetlistItem(songID: song.id, versionID: version.id, performanceKey: version.writtenKey, section: section))
                                dismiss()
                            } label: { VersionHeading(version: version, preferred: stand.library.preferences[song.id] == version.id).frame(minHeight: 56) }
                            .accessibilityIdentifier("addVersion.\(version.id.uuidString)")
                        }
                    }
                }
            }.navigationTitle(section == .planned ? "예정곡 추가" : "대기곡 추가")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } } }
        }
    }
}

struct SetlistItemSheet: View {
    @ObservedObject var stand: MusicStand
    let saved: (SetlistItem) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var item: SetlistItem
    @State private var key: String
    @FocusState private var keyFocused: Bool
    init(stand: MusicStand, initial: SetlistItem, saved: @escaping (SetlistItem) -> Void) {
        self.stand = stand; self.saved = saved; _item = State(initialValue: initial)
        _key = State(initialValue: initial.performanceKey ?? "")
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("이 순서에서 사용할 악보") {
                    Picker("악보 버전", selection: $item.versionID) {
                        ForEach(stand.library.versions(for: item.songID)) { version in
                            Text("v\(version.number) · \(version.writtenKey ?? "?") · \(version.label)").tag(version.id)
                        }
                    }
                    TextField("연주 키 · 예: G, Bb, F#m", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($keyFocused).submitLabel(.done).onSubmit { keyFocused = false }
                        .accessibilityIdentifier("performanceKey")
                    Text("키 표시는 PDF를 바꾸지 않습니다. 악보 키와 연주 키가 다르면 직접 확인해 주세요.").font(.caption).foregroundStyle(.secondary)
                }
                Picker("곡 구분", selection: $item.section) { Text("예정곡").tag(SetlistSection.planned); Text("대기곡").tag(SetlistSection.standby) }
            }.navigationTitle("곡 순서 수정")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("취소") { keyFocused = false; dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("적용") {
                        guard key.trimmed.isEmpty || MusicalKey.isValid(key.trimmed) else {
                            stand.error = String(localized: "키를 G, Bb, F#m처럼 입력해 주세요."); return
                        }
                        keyFocused = false
                        item.performanceKey = key.trimmed.isEmpty ? nil : key.trimmed; saved(item); dismiss()
                    }.accessibilityIdentifier("applySetlistItem") }
                }.workspaceError(stand)
        }
    }
}
