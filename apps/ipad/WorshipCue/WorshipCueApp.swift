import SwiftUI
import UniformTypeIdentifiers

@main struct WorshipCueApp: App {
    var body: some Scene { WindowGroup { MusicStandScreen() } }
}

struct MusicStandScreen: View {
    @StateObject private var stand: MusicStand
    @State private var importing = false
    @State private var colorsPresented = false
    @State private var workspacePresented = false
    @State private var exportPresented = false
    @State private var transferPresented = false
    @Environment(\.scenePhase) private var scenePhase

    init() {
        var testRoot: URL?
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--ui-test-store"),
           arguments.indices.contains(index + 1),
           let run = UUID(uuidString: arguments[index + 1]),
           let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            // UI tests get a separate, UUID-scoped store; the normal user's files
            // and bookmarks are never opened or reset by test launches.
            testRoot = support.appendingPathComponent("WorshipCueUITests").appendingPathComponent(run.uuidString)
        }
        #endif
        _stand = StateObject(wrappedValue: MusicStand(applicationSupport: testRoot))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("WorshipCue").font(.headline)
                    Text(stand.current?.name ?? String(localized: "악보 준비 중…"))
                        .font(.subheadline).lineLimit(2).accessibilityIdentifier("currentChart")
                }
                Spacer()
                Button { workspacePresented = true } label: { Label("오늘 · 라이브러리", systemImage: "music.note.list") }
                    .frame(minHeight: 44).accessibilityIdentifier("openWorkspace")
                Button { exportPresented = true } label: { Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44) }
                    .accessibilityLabel(Text("PDF 내보내기")).accessibilityIdentifier("openExport")
                    .disabled(stand.current == nil || stand.busy)
                Menu {
                    ForEach(stand.charts) { chart in
                        Button(chart.name) { Task { await stand.choose(chart) } }
                    }
                    Button("파일에서 PDF 가져오기") { importing = true }
                } label: { Label("악보 선택", systemImage: "doc") }
                .disabled(stand.busy).frame(minHeight: 44)
                .accessibilityIdentifier("chartChooser")
            }
            .padding(.horizontal).padding(.top, 10)

            Picker("필기 입력", selection: Binding(get: { stand.fingerTesting }, set: stand.setFingerTesting)) {
                Text("Apple Pencil").tag(false)
                Text("손가락 필기").tag(true)
            }
            .pickerStyle(.segmented).frame(minHeight: 44)
            .disabled(stand.busy)
            .accessibilityIdentifier("inputMode")
            .padding(.horizontal)
            Text(stand.fingerTesting
                 ? String(localized: "손가락으로 필기합니다. 악보를 이동·확대하려면 Apple Pencil 모드로 전환하세요.")
                 : String(localized: "Apple Pencil로 필기 · 손가락으로 악보 이동·확대"))
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)

            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    control("펜", "pencil.tip", selected: stand.selectedToolKind == 0) { stand.setTool(0) }.accessibilityIdentifier("tool.pen")
                    control("형광펜", "highlighter", selected: stand.selectedToolKind == 1) { stand.setTool(1) }.accessibilityIdentifier("tool.marker")
                    colorControl
                    control("획 지우개", "eraser", selected: stand.selectedToolKind == 2) { stand.setTool(2) }.accessibilityIdentifier("tool.eraser")
                    control("실행 취소", "arrow.uturn.backward") { stand.undo() }.accessibilityIdentifier("tool.undo")
                    control("다시 실행", "arrow.uturn.forward") { stand.redo() }.accessibilityIdentifier("tool.redo")
                    control("메모 선택", "rectangle.dashed") { stand.beginSelection() }.accessibilityIdentifier("tool.select")
                    control("붙여넣기", "doc.on.clipboard") { stand.beginPaste() }.accessibilityIdentifier("tool.paste")
                        .disabled(stand.clipboard.selection == nil)
                    control("다른 악보로 메모 복사", "arrow.up.doc.on.clipboard") { transferPresented = true }
                        .disabled(stand.clipboard.selection == nil).accessibilityIdentifier("tool.transferDestination")
                    Toggle("팀 예시 읽기 전용", isOn: Binding(get: { stand.teamVisible }, set: stand.showTeam))
                        .fixedSize().frame(minHeight: 44).accessibilityIdentifier("teamSample")
                }.padding(.horizontal)
            }
            .accessibilityIdentifier("toolStrip")
            .disabled(stand.busy)
            if stand.transferMode == .select {
                HStack {
                    Text("사각형으로 개인 메모를 선택해 주세요.")
                    Spacer()
                    Button("선택 복사 (\(stand.selectionCount))") { stand.copySelection() }
                        .disabled(stand.selectionCount == 0).frame(minHeight: 44).accessibilityIdentifier("copySelection")
                    Button("취소") { stand.cancelTransfer() }.frame(minHeight: 44).accessibilityIdentifier("cancelTransfer")
                }.padding(.horizontal)
            } else if stand.transferMode == .paste {
                HStack {
                    Text("미리보기를 드래그해 위치를 정해 주세요.")
                    Spacer()
                    Button("축소") { stand.scalePaste(0.8) }.frame(minHeight: 44).accessibilityIdentifier("scaleDown")
                    Button("확대") { stand.scalePaste(1.25) }.frame(minHeight: 44).accessibilityIdentifier("scaleUp")
                    Button("붙여넣기 확정") { stand.commitPaste() }.frame(minHeight: 44).accessibilityIdentifier("commitPaste")
                    Button("취소") { stand.cancelTransfer() }.frame(minHeight: 44).accessibilityIdentifier("cancelTransfer")
                }.padding(.horizontal)
            }
            if stand.teamVisible {
                Text("팀 예시는 곡 A v2의 첫 페이지에만 표시됩니다.")
                    .font(.caption).padding(.horizontal)
            }
            Divider()
            PDFStandView(stand: stand)
            Divider()
            HStack {
                Button { Task { await stand.turnPage(-1) } } label: { Label("이전", systemImage: "chevron.left").frame(minWidth: 56, minHeight: 56) }
                    .disabled(stand.pageIndex == 0 || stand.busy).accessibilityIdentifier("previousPage")
                Text("\(stand.pageCount == 0 ? 0 : stand.pageIndex + 1) / \(stand.pageCount)")
                    .monospacedDigit().accessibilityLabel(Text("현재 페이지 \(stand.pageIndex + 1), 전체 \(stand.pageCount)"))
                    .accessibilityIdentifier("pagePosition")
                Button { Task { await stand.turnPage(1) } } label: { Label("다음", systemImage: "chevron.right").frame(minWidth: 56, minHeight: 56) }
                    .disabled(stand.pageIndex + 1 >= stand.pageCount || stand.busy).accessibilityIdentifier("nextPage")
                Spacer()
                Text(stand.status).font(.subheadline).accessibilityIdentifier("saveStatus")
                Button { Task { await stand.retrySave() } } label: { Text("저장 확인").frame(minHeight: 44) }
            }.frame(minHeight: 56).padding(.horizontal)
        }
        .task { await stand.start() }
        .sheet(isPresented: $workspacePresented) { WorkspaceView(stand: stand) }
        .sheet(isPresented: $exportPresented) { ExportSheet(stand: stand) }
        .sheet(isPresented: $transferPresented) { TransferDestinationSheet(stand: stand) }
        .onChange(of: stand.selectedToolKind) { _ in colorsPresented = false }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf]) { result in
            switch result {
            case .success(let url): Task { await stand.importFile(url) }
            case .failure: stand.error = String(localized: "파일 선택을 완료하지 못했어요.")
            }
        }
        .alert("확인 필요", isPresented: Binding(get: { stand.error != nil }, set: { if !$0 { stand.error = nil } })) {
            Button("저장 다시 시도") { Task { await stand.retrySave() } }
            Button("닫기", role: .cancel) { stand.error = nil }
        } message: { Text(stand.error ?? "") }
        .onChange(of: scenePhase) { phase in
            guard phase != .active else { return }
            let task = UIApplication.shared.beginBackgroundTask(withName: "Save personal ink")
            Task {
                await stand.retrySave()
                if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
            }
        }
    }

    private var colorControl: some View {
        Button { colorsPresented.toggle() } label: {
            HStack(spacing: 4) {
                Circle().fill(Color(uiColor: stand.selectedInkColor.uiColor))
                    .frame(width: 22, height: 22)
                    .overlay(Circle().strokeBorder(.secondary, lineWidth: 1))
                Image(systemName: "chevron.down").font(.caption2)
            }.frame(minWidth: 44, minHeight: 44)
        }
        .disabled(stand.selectedToolKind == 2)
        .accessibilityLabel(stand.selectedToolKind == 1 ? Text("형광펜 색상") : Text("펜 색상"))
        .accessibilityValue(Text(stand.selectedInkColor.name))
        .accessibilityHint(Text("색상 선택 열기"))
        .accessibilityIdentifier("inkColorPicker")
        .popover(isPresented: $colorsPresented, arrowEdge: .top) {
            VStack(spacing: 12) {
                HStack {
                    Text(stand.selectedToolKind == 1 ? String(localized: "형광펜 색상") : String(localized: "펜 색상"))
                        .font(.headline)
                    Spacer()
                    Button { colorsPresented = false } label: {
                        Image(systemName: "xmark").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(Text("닫기"))
                    .accessibilityIdentifier("closeInkColors")
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 12) {
                    ForEach(InkColor.allCases) { color in
                        Button {
                            stand.setInkColor(color)
                            colorsPresented = false
                        } label: {
                            VStack(spacing: 4) {
                                Circle().fill(Color(uiColor: color.uiColor))
                                    .frame(width: 36, height: 36)
                                    .overlay(Circle().strokeBorder(.secondary.opacity(0.5), lineWidth: 1))
                                    .overlay {
                                        if stand.selectedInkColor == color {
                                            Image(systemName: "checkmark").font(.headline)
                                                .foregroundStyle(color == .yellow || color == .orange ? .black : .white)
                                        }
                                    }
                                Text(color.name).font(.caption).foregroundStyle(.primary)
                            }.frame(maxWidth: .infinity, minHeight: 60)
                        }
                        .accessibilityLabel(Text(color.name))
                        .accessibilityAddTraits(stand.selectedInkColor == color ? .isSelected : [])
                        .accessibilityIdentifier("inkColor.\(color.rawValue)")
                    }
                }
                Text("색상을 선택하면 닫힙니다.").font(.caption).foregroundStyle(.secondary)
            }.padding(16).frame(width: 288)
        }
    }

    private func control(_ title: LocalizedStringKey, _ icon: String, selected: Bool = false,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Label(title, systemImage: icon)
                if selected { Image(systemName: "checkmark.circle.fill").accessibilityHidden(true) }
            }.frame(minHeight: 44)
        }
            .fixedSize()
            .accessibilityValue(selected ? Text("선택됨") : Text(""))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
