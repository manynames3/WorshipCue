import SwiftUI
import UniformTypeIdentifiers

@main struct WorshipCueApp: App {
    var body: some Scene { WindowGroup { MusicStandScreen() } }
}

struct MusicStandScreen: View {
    @StateObject private var stand: MusicStand
    @State private var section: StandSection = .reader
    @State private var inspectorPresented = false
    @State private var inputPresented = false
    @State private var importing = false
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
            // The normal user's files and bookmarks are never opened/reset by UI test launches.
            testRoot = support.appendingPathComponent("WorshipCueUITests").appendingPathComponent(run.uuidString)
        }
        if testRoot != nil, arguments.contains("--ui-test-inspector") {
            _inspectorPresented = State(initialValue: true)
        }
        #endif
        _stand = StateObject(wrappedValue: MusicStand(applicationSupport: testRoot))
    }

    var body: some View {
        GeometryReader { geometry in
            let sidebar = geometry.size.width >= 700
            let docked = geometry.size.width >= 1000 && geometry.size.height >= 500
            VStack(spacing: 0) {
                header(compact: geometry.size.width < 900)
                Divider()
                HStack(spacing: 0) {
                    if sidebar { StandNavigation(section: $section).frame(width: 84); Divider() }
                    if section == .reader { reader(docked: docked) }
                    else {
                        WorkspaceView(stand: stand, tab: Binding(get: { section == .library ? 1 : 0 }, set: { section = $0 == 1 ? .library : .today }),
                                      embedded: true, onOpen: { section = .reader })
                    }
                }
                if !sidebar { Divider(); StandNavigation(section: $section, horizontal: true) }
            }
            .background(Color(uiColor: .systemBackground))
            .preferredColorScheme(section == .reader && inspectorPresented && docked ? .dark : .light)
            .sheet(isPresented: Binding(get: { inspectorPresented && !docked }, set: { inspectorPresented = $0 })) {
                inspector(docked: false).padding(12).preferredColorScheme(.dark)
                    .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
            }
        }
        .tint(StandStyle.blue)
        .task { await stand.start() }
        .sheet(isPresented: $exportPresented) { ExportSheet(stand: stand) }
        .sheet(isPresented: $transferPresented) { TransferDestinationSheet(stand: stand) }
        .onChange(of: stand.transferMode) { mode in
            if mode != .inactive { inputPresented = false }
        }
        .onChange(of: section) { _ in inputPresented = false; inspectorPresented = false; stand.cancelTransfer() }
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

    private func header(compact: Bool) -> some View {
        HStack(spacing: compact ? 10 : 20) {
            if !compact { Text("WorshipCue").font(.title3).fontWeight(.semibold); Divider().frame(height: 24) }
            VStack(alignment: .leading, spacing: 4) {
                Text(section == .reader ? (stand.currentSongTitle ?? String(localized: "악보 준비 중…")) : section.title)
                    .font(compact ? .headline : .title3).fontWeight(.semibold).lineLimit(1)
                    .accessibilityLabel(section == .reader ? (stand.current?.name ?? String(localized: "악보 준비 중…")) : section.title)
                    .accessibilityIdentifier("currentChart")
                if compact && section == .reader { saveStatus }
            }
            if section == .reader, let version = stand.currentLibraryVersion {
                Text("v\(version.number) · \(version.writtenKey ?? "?")")
                    .font(.subheadline).monospacedDigit().padding(.horizontal, 12).padding(.vertical, 7)
                    .background(StandStyle.surface, in: Capsule()).accessibilityIdentifier("currentVersionBadge")
            }
            if !compact { saveStatus }
            Spacer(minLength: 0)
            if stand.busy { ProgressView().accessibilityLabel(Text("작업 중")) }
            if section == .reader {
                Button { inspectorPresented.toggle() } label: { Image(systemName: "sidebar.right").frame(width: 44, height: 44) }
                    .buttonStyle(.plain).background(StandStyle.surface, in: Circle())
                    .accessibilityLabel(Text("버전과 메모")).accessibilityIdentifier("openVersionInspector")
                inputControl
            }
            Menu {
                Button { section = .today } label: { Label("오늘 · 라이브러리", systemImage: "music.note.list") }
                    .accessibilityIdentifier("openWorkspace")
                Button { exportPresented = true } label: { Label("PDF 내보내기", systemImage: "square.and.arrow.up") }
                    .disabled(stand.current == nil || stand.busy).accessibilityIdentifier("openExport")
                Button { Task { await stand.retrySave() } } label: { Label("저장 확인", systemImage: "checkmark.shield") }
                Button { importing = true } label: { Label("파일에서 PDF 가져오기", systemImage: "doc.badge.plus") }
            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44).background(StandStyle.surface, in: Circle()) }
                .accessibilityLabel(Text("악보 작업")).accessibilityIdentifier("standActions")
        }.padding(.horizontal, 18).frame(minHeight: 68)
    }

    private var saveStatus: some View {
        HStack(spacing: 6) {
            Image(systemName: stand.error == nil ? "ipad" : "exclamationmark.triangle").accessibilityHidden(true)
            Text(stand.status).lineLimit(1).accessibilityIdentifier("saveStatus")
        }.font(.caption).foregroundStyle(stand.error == nil ? Color.secondary : Color.orange)
    }

    private var inputControl: some View {
        Button { inputPresented.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: stand.fingerTesting ? "hand.draw" : "pencil.tip")
                Text(stand.fingerTesting ? "터치" : "Pencil").font(.caption)
            }.padding(.horizontal, 10).frame(minHeight: 44)
                .background(StandStyle.surface, in: Capsule())
        }.buttonStyle(.plain)
            .accessibilityLabel(Text("필기 입력 설정"))
            .accessibilityValue(stand.fingerTesting ? Text("손가락 필기") : Text("Apple Pencil"))
            .accessibilityIdentifier("openInputMode")
            .popover(isPresented: $inputPresented, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("필기 입력").font(.headline)
                        Spacer()
                        Button { inputPresented = false } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                            .accessibilityLabel(Text("닫기")).accessibilityIdentifier("closeInputMode")
                    }
                    Picker("필기 입력", selection: Binding(get: { stand.fingerTesting }, set: { stand.setFingerTesting($0); inputPresented = false })) {
                        Text("Apple Pencil").tag(false); Text("손가락 필기").tag(true)
                    }.pickerStyle(.segmented).accessibilityIdentifier("inputMode")
                    Text(stand.fingerTesting ? String(localized: "손가락으로 필기합니다. 악보를 이동·확대하려면 Apple Pencil 모드로 전환하세요.")
                         : String(localized: "Apple Pencil로 필기 · 손가락으로 악보 이동·확대"))
                        .font(.subheadline).foregroundStyle(.secondary)
                    Divider()
                    Toggle("팀 예시 읽기 전용", isOn: Binding(get: { stand.teamVisible }, set: stand.showTeam)).accessibilityIdentifier("teamSample")
                    Text("팀 예시는 곡 A v2의 첫 페이지에만 표시됩니다.").font(.caption).foregroundStyle(.secondary)
                }.padding(18).frame(width: 320).preferredColorScheme(.light)
            }
    }

    private func reader(docked: Bool) -> some View {
        HStack(spacing: 10) {
            VStack(spacing: 0) {
                PDFStandView(stand: stand)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(StandStyle.border))
                    .accessibilityIdentifier("readerSurface")
                if stand.transferMode != .inactive && !(docked && inspectorPresented) {
                    TransferActions(stand: stand).padding(12).background(StandStyle.surface, in: RoundedRectangle(cornerRadius: 12))
                }
                pageControls
            }
            StandTools(stand: stand, select: {
                stand.beginSelection()
                if docked { inspectorPresented = true }
            }, paste: {
                stand.beginPaste()
                if docked { inspectorPresented = true }
            }, destination: { transferPresented = true })
                .clipShape(RoundedRectangle(cornerRadius: 12))
            if docked && inspectorPresented { inspector(docked: true).frame(width: 320) }
        }.padding(.horizontal, 10).padding(.top, 10)
    }

    private func inspector(docked: Bool) -> some View {
        VersionInspector(stand: stand, close: { inspectorPresented = false; stand.cancelTransfer() }, select: {
            stand.beginSelection()
            if !docked { inspectorPresented = false }
        }, preview: {
            stand.requestPastePreview()
            if !docked { inspectorPresented = false }
        }, destination: {
            inspectorPresented = false
            transferPresented = true
        })
    }

    private var pageControls: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(stand.charts) { chart in Button(chart.name) { Task { await stand.choose(chart) } } }
            } label: { Image(systemName: "doc.on.doc").frame(width: 44, height: 44) }
                .accessibilityLabel(Text("악보 선택")).accessibilityIdentifier("chartChooser").disabled(stand.busy)
            Spacer(minLength: 0)
            Button { Task { await stand.turnPage(-1) } } label: { Image(systemName: "chevron.left").frame(width: 56, height: 56) }
                .buttonStyle(.plain).background(StandStyle.surface, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel(Text("이전")).disabled(stand.pageIndex == 0 || stand.busy).accessibilityIdentifier("previousPage")
            Text("\(stand.pageCount == 0 ? 0 : stand.pageIndex + 1) / \(stand.pageCount)")
                .font(.subheadline).monospacedDigit().frame(minWidth: 52)
                .accessibilityLabel(Text("현재 페이지 \(stand.pageIndex + 1), 전체 \(stand.pageCount)"))
                .accessibilityIdentifier("pagePosition")
            Button { Task { await stand.turnPage(1) } } label: { Image(systemName: "chevron.right").frame(width: 56, height: 56) }
                .buttonStyle(.plain).background(StandStyle.surface, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel(Text("다음")).disabled(stand.pageIndex + 1 >= stand.pageCount || stand.busy).accessibilityIdentifier("nextPage")
            Spacer(minLength: 0)
            Image(systemName: "lock").font(.subheadline).frame(width: 44, height: 44)
                .foregroundStyle(.secondary).accessibilityLabel(Text("개인 메모"))
        }.padding(.vertical, 8)
    }
}
