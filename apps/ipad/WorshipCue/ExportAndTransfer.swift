import SwiftUI
import WorshipCueLocal

private struct ExportFile: Identifiable { let id = UUID(); let url: URL }
struct ExportSheet: View {
    @ObservedObject var stand: MusicStand
    @Environment(\.dismiss) private var dismiss
    @State private var personal = true
    @State private var exported: ExportFile?
    var body: some View {
        NavigationStack {
            Form {
                Section("내보낼 악보") { Text(stand.current?.name ?? "").textSelection(.enabled); Text("전체 \(stand.pageCount)쪽") }
                Section("포함할 레이어") {
                    Label("원본 PDF · 편곡자 메모 포함", systemImage: "doc.fill")
                    Toggle("내 개인 메모 포함", isOn: $personal).accessibilityIdentifier("exportPersonalInk")
                    Text("원본 PDF와 선택한 개인 메모로 새 PDF를 만듭니다. 앱의 팀 예시 레이어는 포함하지 않습니다. 원본과 편집 가능한 개인 메모는 유지됩니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button { Task { if let url = await stand.exportPDF(includePersonal: personal) { exported = ExportFile(url: url) } } } label: {
                    Label(stand.busy ? String(localized: "PDF 만드는 중…") : String(localized: "PDF 만들고 공유하기"), systemImage: "square.and.arrow.up")
                }.frame(minHeight: 56).disabled(stand.busy).accessibilityIdentifier("createExport")
            }.navigationTitle("PDF 백업 · 내보내기")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() }.disabled(stand.busy) } }
                .sheet(item: $exported) { SharePDF(url: $0.url) }
                .workspaceError(stand).interactiveDismissDisabled(stand.busy)
        }
    }
}
private struct SharePDF: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct TransferDestinationSheet: View {
    @ObservedObject var stand: MusicStand
    var openVersion: ((UUID, Int) async -> Bool)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var versionID: UUID?
    @State private var page = 1
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    private var pageCount: Int {
        stand.library.assets.first { $0.id == versionID }?.pages?.count ?? 1
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("선택한 개인 메모만 복사합니다. 대상 악보·페이지를 고른 뒤 미리보기에서 위치와 크기를 직접 정하고 확정하세요.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    TextField("곡 검색", text: $query).focused($searchFocused).accessibilityIdentifier("transferSongSearch")
                }
                ForEach(stand.library.search(query)) { song in
                    Section(song.title) {
                        ForEach(stand.library.versions(for: song.id)) { version in
                            Button { if stand.verifyVersion(version.id) != nil { searchFocused = false; versionID = version.id; page = 1 } } label: {
                                HStack {
                                    VersionHeading(version: version)
                                    Spacer()
                                    if versionID == version.id { Image(systemName: "checkmark.circle.fill") }
                                }.frame(minHeight: 56)
                            }.accessibilityIdentifier("transferVersion.\(version.id.uuidString)")
                        }
                    }
                }
                if versionID != nil {
                    Section("대상 페이지") {
                        Stepper("\(page) / \(pageCount)쪽", value: $page, in: 1...max(1, pageCount))
                            .accessibilityIdentifier("transferDestinationPage")
                        Text("기존 메모와 원본은 바꾸지 않습니다. 붙여넣기는 취소하거나 실행 취소할 수 있습니다.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.navigationTitle("메모 복사 대상")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("붙여넣기 미리보기") { Task {
                        if let versionID {
                            let opened: Bool
                            if let openVersion { opened = await openVersion(versionID, page - 1) }
                            else { opened = await stand.openVersion(versionID, page: page - 1) }
                            if opened { stand.requestPastePreview(); dismiss() }
                        }
                    } }.disabled(versionID == nil || stand.busy).accessibilityIdentifier("openTransferDestination") }
                }.workspaceError(stand)
        }
    }
}
