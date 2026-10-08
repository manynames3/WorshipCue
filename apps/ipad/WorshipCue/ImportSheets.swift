import SwiftUI
import WorshipCueLocal
import WorshipCueCore

struct ImportChartSheet: View {
    @ObservedObject var stand: MusicStand
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var songID: UUID?
    @State private var title: String
    @State private var label: String
    @State private var key = ""
    init(stand: MusicStand, url: URL, initialSongID: UUID? = nil) {
        self.stand = stand; self.url = url; _songID = State(initialValue: initialSongID)
        let filename = url.deletingPathExtension().lastPathComponent.precomposedStringWithCanonicalMapping
        _title = State(initialValue: filename); _label = State(initialValue: filename)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("가져올 PDF") { Text(url.lastPathComponent).textSelection(.enabled) }
                Section("곡 연결") {
                    Picker("곡", selection: $songID) {
                        Text("새 곡으로 추가").tag(UUID?.none)
                        ForEach(stand.library.songs) { Text($0.title).tag(Optional($0.id)) }
                    }.accessibilityIdentifier("importSongChoice")
                    if songID == nil { TextField("새 곡 제목", text: $title).accessibilityIdentifier("importSongTitle") }
                    Text(songID == nil ? "새 곡의 첫 버전으로 저장합니다." : "이 곡의 새 버전으로 저장합니다. 기존 PDF와 메모는 그대로 유지됩니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("악보 정보") {
                    TextField("버전 이름 · 예: 편곡자 · 날짜", text: $label).accessibilityIdentifier("importVersionLabel")
                    TextField("악보에 적힌 키 · 예: G, Bb, F#m", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("모르는 키는 비워 두세요. 키 표시는 PDF를 조옮김하지 않습니다.").font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Text("주간 PDF에 여러 곡이 있다면 먼저 원본을 가져온 뒤 악보 작업에서 페이지 범위를 지정해 나눌 수 있습니다.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }.navigationTitle("PDF 가져오기")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() }.disabled(stand.busy) }
                    ToolbarItem(placement: .confirmationAction) { Button(stand.busy ? "가져오는 중…" : "가져오기") { Task {
                        let song = songID.flatMap { id in stand.library.songs.first { $0.id == id } } ?? LibrarySong(title: title.trimmed)
                        if await stand.importChart(url, song: song, label: label.trimmed, writtenKey: key.trimmed.isEmpty ? nil : key.trimmed) { dismiss() }
                    } }.disabled(stand.busy || label.trimmed.isEmpty || (songID == nil && title.trimmed.isEmpty)) }
                }.workspaceError(stand)
                .interactiveDismissDisabled(stand.busy)
        }
    }
}

private struct SliceDraft: Identifiable {
    let id = UUID()
    var songID: UUID?
    var title = ""
    var first = "1"
    var last = "1"
    var key = ""
    var label = ""
}
struct PacketImportSheet: View {
    @ObservedObject var stand: MusicStand
    let chart: LocalChart
    @Environment(\.dismiss) private var dismiss
    @State private var ranges = [SliceDraft()]
    private var pages: Int? { stand.library.assets.first { $0.id == chart.id }?.pages?.count }
    var body: some View {
        NavigationStack {
            Form {
                Section("주간 원본") {
                    Text(chart.name).textSelection(.enabled)
                    if let pages { Text("전체 \(pages)쪽") }
                    Text("한 곡의 시작·끝 페이지를 직접 지정하세요. 표지나 안내 페이지는 빼도 됩니다. 원본과 편곡자 메모를 보존하고 별도 PDF로 저장합니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach($ranges) { $range in
                    let position = ranges.firstIndex { $0.id == range.id } ?? 0
                    Section("곡 \(position + 1)") {
                        Picker("곡 연결", selection: $range.songID) {
                            Text("새 곡").tag(UUID?.none)
                            ForEach(stand.library.songs) { Text($0.title).tag(Optional($0.id)) }
                        }
                        if range.songID == nil { TextField("곡 제목", text: $range.title).accessibilityIdentifier("packetTitle.\(position)") }
                        HStack {
                            TextField("시작 쪽", text: $range.first).keyboardType(.numberPad).accessibilityLabel(Text("시작 쪽"))
                                .accessibilityIdentifier("packetFirst.\(position)")
                            Text("–")
                            TextField("끝 쪽", text: $range.last).keyboardType(.numberPad).accessibilityLabel(Text("끝 쪽"))
                                .accessibilityIdentifier("packetLast.\(position)")
                        }
                        TextField("악보 키 · 선택 사항", text: $range.key).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("packetKey.\(position)")
                        TextField("버전 이름 · 비우면 원본 이름 사용", text: $range.label).accessibilityIdentifier("packetLabel.\(position)")
                        Button("이 범위 삭제", role: .destructive) { ranges.removeAll { $0.id == range.id } }
                    }
                }
                Button("다른 곡 범위 추가") { ranges.append(SliceDraft()) }.disabled(ranges.count >= 200).accessibilityIdentifier("addPacketRange")
            }.navigationTitle("주간 PDF 곡 나누기")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() }.disabled(stand.busy) }
                    ToolbarItem(placement: .confirmationAction) { Button("곡 가져오기") { Task {
                        var slices: [PacketSlice] = []
                        for range in ranges {
                            guard let first = Int(range.first.trimmed), let last = Int(range.last.trimmed),
                                  first > 0, first <= last, range.key.trimmed.isEmpty || MusicalKey.isValid(range.key.trimmed) else {
                                stand.error = String(localized: "시작·끝 페이지와 악보 키를 확인해 주세요."); return
                            }
                            let song = range.songID.flatMap { id in stand.library.songs.first { $0.id == id } } ?? LibrarySong(title: range.title.trimmed)
                            slices.append(PacketSlice(song: song, firstPage: first, lastPage: last,
                                writtenKey: range.key.trimmed.isEmpty ? nil : range.key.trimmed,
                                label: range.label.trimmed.isEmpty ? chart.name + " · \(first)–\(last)" : range.label.trimmed))
                        }
                        if await stand.splitPacket(chart.id, slices: slices) { dismiss() }
                    } }.disabled(stand.busy || ranges.isEmpty).accessibilityIdentifier("importPacketRanges") }
                }.workspaceError(stand).interactiveDismissDisabled(stand.busy)
                .task { _ = stand.verifyVersion(chart.id) }
        }
    }
}
