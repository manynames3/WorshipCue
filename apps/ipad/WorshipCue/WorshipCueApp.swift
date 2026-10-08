import SwiftUI
import UniformTypeIdentifiers
import WorshipCueCore

@main struct WorshipCueApp: App {
    var body: some Scene { WindowGroup { MusicStandScreen() } }
}

struct MusicStandScreen: View {
    @StateObject private var localStand: MusicStand
    @StateObject private var team: TeamWorkspace
    private var stand: MusicStand { team.reader ?? localStand }
    @State private var teamPresented = false
    @State private var teamPreview = false
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
        if testRoot == nil, ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil,
           let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            // Hosted native tests also isolate app startup, before any normal chart/session can be restored.
            testRoot = support.appendingPathComponent("WorshipCueHostedTests").appendingPathComponent(UUID().uuidString)
        }
        if testRoot != nil, arguments.contains("--ui-test-inspector") {
            _inspectorPresented = State(initialValue: true)
        }
        #endif
        _localStand = StateObject(wrappedValue: MusicStand(applicationSupport: testRoot))
        _team = StateObject(wrappedValue: TeamWorkspace(testRoot: testRoot))
    }

    var body: some View {
        GeometryReader { geometry in
            let sidebar = geometry.size.width >= 700
            let docked = geometry.size.width >= 1000 && geometry.size.height >= 500
            VStack(spacing: 0) {
                header(compact: geometry.size.width < 900)
                Divider()
                SongCueBanner(team: team, opened: { section = .reader })
                HStack(spacing: 0) {
                    if sidebar { StandNavigation(section: $section).frame(width: 84); Divider() }
                    if section == .reader { reader(docked: docked) }
                    else {
                        WorkspaceView(stand: localStand, tab: Binding(get: { section == .library ? 1 : 0 }, set: { section = $0 == 1 ? .library : .today }),
                                      embedded: true, onOpen: { Task { if await team.useLocalReader() { section = .reader } } })
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
        .task { await localStand.start(); await team.restore() }
        .sheet(isPresented: $teamPresented) { TeamPanel(team: team, local: localStand, opened: { section = .reader }) }
        .sheet(isPresented: $teamPreview) { if let call = team.displayedCall { TeamInkSheet(team: team, call: call, editable: false) } }
        .onChange(of: stand.current?.id) { _ in team.navigationChanged(); Task { try? await team.refreshShared() } }
        .onChange(of: stand.pageIndex) { _ in team.navigationChanged(); Task { try? await team.refreshShared() } }
        .sheet(isPresented: $exportPresented) { ExportSheet(stand: stand) }
        .sheet(isPresented: $transferPresented) { TransferDestinationSheet(stand: stand, openVersion: { id, page in
            if team.reader != nil { return await team.openVersion(id, page: page) }
            return await stand.openVersion(id, page: page)
        }) }
        .onChange(of: stand.transferMode) { mode in
            if mode != .inactive { inputPresented = false }
        }
        .onChange(of: section) { _ in inputPresented = false; inspectorPresented = false; stand.cancelTransfer() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf]) { result in
            switch result {
            case .success(let url): Task { if await team.useLocalReader() { await localStand.importFile(url); section = .reader } }
            case .failure: localStand.error = String(localized: "파일 선택을 완료하지 못했어요.")
            }
        }
        .alert("확인 필요", isPresented: Binding(get: { stand.error != nil }, set: { if !$0 { stand.error = nil } })) {
            Button("저장 다시 시도") { Task { await stand.retrySave() } }
            Button("닫기", role: .cancel) { stand.error = nil }
        } message: { Text(stand.error ?? "") }
        .onChange(of: scenePhase) { phase in
            if phase == .active { Task { await team.resume() }; return }
            team.suspend()
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
            if section == .reader, team.reader != nil, let key = team.currentPerformanceKey {
                Text("연주 키 \(key)").font(.subheadline).foregroundStyle(StandStyle.blue)
                if let written = stand.currentLibraryVersion?.writtenKey, MusicalKey.compare(written: written, performance: key) == .different {
                    Label("악보 키가 달라요", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
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
                Button { teamPresented = true } label: { Label("팀 작업 공간", systemImage: "person.2") }.accessibilityIdentifier("openTeamWorkspace")
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
                    if team.reader == nil {
                        Divider()
                        Toggle("팀 예시 읽기 전용", isOn: Binding(get: { stand.teamVisible }, set: stand.showTeam)).accessibilityIdentifier("teamSample")
                        Text("팀 예시는 곡 A v2의 첫 페이지에만 표시됩니다.").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(18).frame(width: 320).preferredColorScheme(.light)
            }
    }

    private func reader(docked: Bool) -> some View {
        HStack(spacing: 10) {
            VStack(spacing: 0) {
                PDFStandView(stand: stand).id(ObjectIdentifier(stand))
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
        }, prefer: { version in
            if team.reader != nil { Task { await team.prefer(version.id) } }
            else { stand.prefer(version) }
        }, openVersion: { id in
            if team.reader != nil { Task { _ = await team.openVersion(id) } }
            else { Task { _ = await stand.openVersion(id) } }
        })
    }

    private var pageControls: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(stand.charts) { chart in Button(chart.name) {
                    Task { if team.reader != nil { _ = await team.openVersion(chart.id) } else { await stand.choose(chart) } }
                } }
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
            if team.reader != nil, team.teamMismatch {
                Button("팀 악보 미리보기") { teamPreview = true }.frame(minHeight: 44).foregroundStyle(.orange)
            }
            Image(systemName: "lock").font(.subheadline).frame(width: 44, height: 44)
                .foregroundStyle(.secondary).accessibilityLabel(Text("개인 메모"))
        }.padding(.vertical, 8)
    }
}
