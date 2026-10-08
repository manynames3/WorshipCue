import SwiftUI
import PDFKit
import PencilKit
import WorshipCueCore
import WorshipCueLocal
import WorshipCueRemote

@MainActor final class TeamInkDraft: ObservableObject {
    @Published var drawing = PKDrawing()
    @Published var document: PDFDocument?
    @Published var page = 0
    @Published var geometry: PageGeometry?
    @Published var ready = false
    @Published var publishing = false
    @Published var writing = false
    private var loadGeneration: UInt64 = 0
    @Published var dirty = false
    @Published var error: String?
    @Published var color: InkColor = .red
    @Published var marker = false
    @Published var eraser = false
    @Published var finger = false
    private var parent: Int64 = 0
    private var command = UUID()
    private var payload: TeamJSON = .null
    private let team: TeamWorkspace
    private let context: UUID
    let call: LiveCall
    let editable: Bool
    weak var canvas: PersonalCanvas?
    init(team: TeamWorkspace, call: LiveCall, editable: Bool, initialPage: Int = 0) {
        self.team = team; self.call = call; self.editable = editable; context = team.scopeID; page = initialPage
    }
    var tool: PKTool { eraser ? PKEraserTool(.vector) : PKInkingTool(marker ? .marker : .pen, color: color.uiColor, width: marker ? 18 : 2) }
    var canTurnPages: Bool { document != nil && (!editable || ready) && !publishing && !writing }
    func load() async {
        loadGeneration &+= 1
        let generation = loadGeneration, targetPage = page
        ready = false; drawing = PKDrawing(); canvas?.isUserInteractionEnabled = false
        do {
            guard team.scopeID == context else { throw RemoteError.authentication }
            let stand = try await team.preparedVersion(call.teamChartVersionID)
            let bytes = try stand.sourceBytes(call.teamChartVersionID)
            guard let doc = PDFDocument(data: bytes), let current = doc.page(at: targetPage) else { throw VaultError.invalidPDF }
            let newGeometry = try current.canonicalGeometry()
            guard team.scopeID == context, loadGeneration == generation, page == targetPage else { return }
            // Verified paper remains readable even when the exact ink head has not been cached.
            document = doc; geometry = newGeometry
            var newDrawing: PKDrawing, newParent: Int64, newCommand = UUID(), newPayload: TeamJSON = .null, newDirty = false
            if editable {
                let saved = try team.teamDraft(call.performanceItemID, chart: call.teamChartVersionID, page: targetPage)
                if saved != .null, let archive = saved["archive"].text, let data = Data(base64Encoded: archive) {
                    newDrawing = try PKDrawing(data: data); newParent = saved["parent_revision"].integer ?? 0
                    newCommand = try saved.requiredID("command_id"); newPayload = saved["payload"]; newDirty = true
                } else {
                    let remote = try await team.loadTeamDrawing(item: call.performanceItemID, chart: call.teamChartVersionID, page: targetPage)
                    newDrawing = remote.0; newParent = remote.1["revision_number"].integer ?? 0
                }
            } else {
                let remote = try await team.loadTeamDrawing(item: call.performanceItemID, chart: call.teamChartVersionID, page: targetPage)
                newDrawing = remote.0; newParent = remote.1["revision_number"].integer ?? 0
            }
            guard team.scopeID == context, loadGeneration == generation, page == targetPage else { return }
            geometry = newGeometry; document = doc; drawing = newDrawing; parent = newParent
            command = newCommand; payload = newPayload; dirty = newDirty
            ready = true; canvas?.isUserInteractionEnabled = editable; error = nil
        } catch {
            guard team.scopeID == context, loadGeneration == generation, page == targetPage else { return }
            self.error = document == nil
                ? String(localized: "팀 악보·메모를 확인하지 못했어요. 현재 연주 화면은 유지됩니다.")
                : String(localized: "팀 메모를 확인하지 못했어요. 저장된 팀 악보는 읽을 수 있습니다. 연결되면 다시 확인해 주세요.")
        }
    }
    func changed(_ value: PKDrawing) {
        guard team.scopeID == context, ready, editable, !publishing else { return }
        drawing = value; dirty = true
        // Each explicit draft edit starts a fresh command; a failed publication's original copy is preserved.
        if payload != .null { command = UUID(); payload = .null }
        persist()
    }
    func persist() {
        guard team.scopeID == context, editable, ready, dirty, !publishing else { return }
        do {
            let archive = drawing.dataRepresentation()
            guard archive.count <= LocalInkStore.maximumArchiveBytes else { throw InkStoreError.archiveTooLarge }
            try team.saveTeamDraft(value(archive), item: call.performanceItemID, chart: call.teamChartVersionID, page: page)
            error = nil
        } catch { self.error = String(localized: "초안을 기기에 저장하지 못했어요. 이 창을 유지하고 저장 공간을 확인해 주세요.") }
    }
    private func value(_ archive: Data) -> TeamJSON {
        .object(["archive": .string(archive.base64EncodedString()), "parent_revision": .int(parent), "command_id": .id(command), "payload": payload])
    }
    func publish() async -> Bool {
        guard team.scopeID == context, editable, !publishing, !writing, ready else { return false }
        drawing = canvas?.drawing ?? drawing
        persist()
        guard error == nil, let geometry else { return false }
        publishing = true; canvas?.isUserInteractionEnabled = false
        defer { publishing = false; canvas?.isUserInteractionEnabled = editable && ready }
        let success = await team.publishTeamDraft(value(drawing.dataRepresentation()), item: call.performanceItemID, chart: call.teamChartVersionID, page: page, geometry: geometry)
        guard team.scopeID == context else { return false }
        if success { dirty = false; await load() }
        else { payload = (try? team.teamDraft(call.performanceItemID, chart: call.teamChartVersionID, page: page))?["payload"] ?? .null }
        return success
    }
    func move(_ delta: Int) async {
        guard canTurnPages else { return }
        if editable { persist(); guard error == nil else { return } }
        guard let document, (0..<document.pageCount).contains(page + delta) else { return }
        dirty = false; page += delta; await load()
    }
    func rebaseExplicitly() async {
        guard team.scopeID == context, editable, ready, !publishing, !writing else { return }
        let generation = loadGeneration, targetPage = page, archive = drawing.dataRepresentation()
        publishing = true; canvas?.isUserInteractionEnabled = false
        defer { publishing = false; canvas?.isUserInteractionEnabled = editable && ready }
        do {
            let remote = try await team.loadTeamDrawing(item: call.performanceItemID, chart: call.teamChartVersionID, page: targetPage)
            guard team.scopeID == context, generation == loadGeneration, targetPage == page else { return }
            // Save the prior proposed and accepted copies before the user chooses a new parent.
            try team.preserveTeamCopies(draft: archive, remote: remote.0.dataRepresentation())
            parent = remote.1["revision_number"].integer ?? 0; command = UUID(); payload = .null; dirty = true
            try team.saveTeamDraft(value(archive), item: call.performanceItemID, chart: call.teamChartVersionID, page: targetPage)
        } catch { self.error = String(localized: "두 사본을 보관하지 못했어요. 기존 초안은 유지됩니다.") }
    }
}

struct TeamInkSheet: View {
    @ObservedObject var team: TeamWorkspace
    @StateObject private var draft: TeamInkDraft
    @Environment(\.dismiss) private var dismiss
    @State private var colors = false
    @State private var confirmReplacement = false
    @State private var serverPreview = false
    init(team: TeamWorkspace, call: LiveCall, editable: Bool, initialPage: Int = 0) {
        self.team = team; _draft = StateObject(wrappedValue: TeamInkDraft(team: team, call: call, editable: editable, initialPage: initialPage))
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text("\(team.songTitle(draft.call.songID)) · 팀 악보 · 개인 메모와 분리됨").font(.subheadline)
                if let document = draft.document, let page = document.page(at: draft.page), let geometry = draft.geometry {
                    TeamDraftSurface(page: page, geometry: geometry, draft: draft).id(draft.page)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else { ContentUnavailablePlaceholder() }
                if let error = draft.error ?? team.error { Text(error).font(.caption).foregroundStyle(.orange) }
                HStack(spacing: 12) {
                    Button { Task { await draft.move(-1) } } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }.disabled(draft.page == 0 || !draft.canTurnPages)
                    Text("\(draft.page + 1) / \(draft.document?.pageCount ?? 0)").monospacedDigit()
                    Button { Task { await draft.move(1) } } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }.disabled(draft.page + 1 >= (draft.document?.pageCount ?? 0) || !draft.canTurnPages)
                    Spacer()
                    if draft.editable {
                        Button(draft.dirty ? "기기 초안 저장" : "기기 초안") { draft.persist() }.disabled(!draft.dirty || draft.publishing || draft.writing || !draft.ready)
                        Button("팀에 게시") { Task { _ = await draft.publish() } }.buttonStyle(.borderedProminent)
                            .disabled(!draft.ready || !draft.dirty || !team.hasLease || !team.online || team.busy || draft.publishing || draft.writing)
                    }
                }
            }.padding(16).background(StandStyle.surface)
                .navigationTitle(draft.editable ? "팀 메모 초안" : "정확한 팀 악보 미리보기")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("닫기") { draft.persist(); if !draft.dirty || draft.error == nil { dismiss() } }.disabled(draft.publishing || draft.writing) }
                    if draft.editable {
                        ToolbarItemGroup(placement: .primaryAction) {
                            Button { draft.eraser = false; draft.marker.toggle() } label: { Image(systemName: draft.marker ? "highlighter" : "pencil.tip").frame(width: 44, height: 44) }.accessibilityLabel(Text("펜·형광펜"))
                                .disabled(!draft.ready || draft.publishing || draft.writing)
                            Button { colors = true } label: { Circle().fill(Color(uiColor: draft.color.uiColor)).frame(width: 22, height: 22).frame(width: 44, height: 44) }.accessibilityLabel(Text("색상"))
                                .disabled(!draft.ready || draft.publishing || draft.writing)
                            Button { draft.canvas?.undoManager?.undo() } label: { Image(systemName: "arrow.uturn.backward").frame(width: 44, height: 44) }.accessibilityLabel(Text("실행 취소"))
                                .disabled(!draft.ready || draft.publishing || draft.writing)
                            Menu {
                                Toggle("손가락 필기", isOn: $draft.finger)
                                Button("지우개") { draft.eraser = true }
                                Button("서버의 팀 메모 먼저 확인") { serverPreview = true }
                                Button("기기 초안으로 서버 사본 교체…") { confirmReplacement = true }
                            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                                .disabled(!draft.ready || draft.publishing || draft.writing)
                        }
                    }
                }
                .popover(isPresented: $colors) { InkColorPalette(selected: draft.color, title: String(localized: "팀 메모 색상"), choose: { draft.color = $0; colors = false }, close: { colors = false }) }
                .confirmationDialog("두 사본을 보관한 뒤 기기의 초안을 새 팀 메모로 게시할 수 있도록 준비합니다. 필기는 자동으로 합치지 않습니다.", isPresented: $confirmReplacement) {
                    Button("두 사본 보관·기기 초안 선택") { Task { await draft.rebaseExplicitly() } }
                }
                .task { await draft.load() }
                .sheet(isPresented: $serverPreview) { TeamInkSheet(team: team, call: draft.call, editable: false, initialPage: draft.page) }
                .onDisappear { draft.persist() }
                .interactiveDismissDisabled(draft.publishing || draft.writing || (draft.dirty && draft.error != nil))
        }.preferredColorScheme(.light)
    }
}

private struct ContentUnavailablePlaceholder: View {
    var body: some View { VStack { Image(systemName: "doc").font(.largeTitle); Text("팀 악보 확인 중"); ProgressView() }.frame(maxWidth: .infinity, maxHeight: .infinity) }
}

private struct TeamDraftSurface: UIViewRepresentable {
    let page: PDFPage
    let geometry: PageGeometry
    @ObservedObject var draft: TeamInkDraft
    func makeCoordinator() -> Coordinator { Coordinator(draft) }
    func makeUIView(context: Context) -> PaperCanvas {
        let view = PaperCanvas(geometry: geometry)
        view.image.image = page.thumbnail(of: CGSize(width: geometry.width, height: geometry.height), for: .cropBox)
        view.canvas.drawing = draft.drawing; view.canvas.delegate = context.coordinator
        view.canvas.isUserInteractionEnabled = draft.editable && draft.ready && !draft.publishing
        view.canvas.accessibilityLabel = String(localized: "팀 메모 · 개인 필기와 별도")
        draft.canvas = view.canvas
        return view
    }
    func updateUIView(_ view: PaperCanvas, context: Context) {
        view.canvas.isUserInteractionEnabled = draft.editable && draft.ready && !draft.publishing
        view.canvas.tool = draft.tool; view.canvas.drawingPolicy = draft.finger ? .anyInput : .pencilOnly
        if view.canvas.drawing.dataRepresentation() != draft.drawing.dataRepresentation() {
            context.coordinator.applying = true; view.canvas.drawing = draft.drawing; context.coordinator.applying = false
        }
    }
    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let draft: TeamInkDraft
        var applying = false
        init(_ draft: TeamInkDraft) { self.draft = draft }
        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) { draft.writing = true }
        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) { draft.writing = false; draft.changed(canvasView.drawing) }
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) { if !applying { draft.changed(canvasView.drawing) } }
    }
}

@MainActor private final class PaperCanvas: UIView {
    let canvas = PersonalCanvas()
    let image = UIImageView()
    let geometry: PageGeometry
    init(geometry: PageGeometry) {
        self.geometry = geometry; super.init(frame: .zero); backgroundColor = .secondarySystemBackground
        overrideUserInterfaceStyle = .light
        image.contentMode = .scaleToFill; addSubview(image); addSubview(canvas)
        canvas.backgroundColor = .clear; canvas.isOpaque = false; canvas.isScrollEnabled = false
        canvas.bounds = CGRect(x: 0, y: 0, width: geometry.width, height: geometry.height)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }
    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = min(bounds.width / geometry.width, bounds.height / geometry.height)
        let size = CGSize(width: geometry.width * scale, height: geometry.height * scale)
        let rect = CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        image.frame = rect; canvas.transform = CGAffineTransform(scaleX: scale, y: scale); canvas.center = CGPoint(x: rect.midX, y: rect.midY)
    }
}

struct PersonalConflictSheet: View {
    @ObservedObject var team: TeamWorkspace
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Text("사본을 직접 선택합니다. 두 사본은 기기에 보관되며 필기는 자동으로 합치지 않습니다.").font(.subheadline)
                ForEach(team.conflicts) { conflict in
                    Section("페이지 \(conflict.remote.address.pageIndex + 1)") {
                        HStack {
                            inkPreview(conflict.local, title: String(localized: "기기의 메모"))
                            inkPreview(conflict.remote, title: String(localized: "서버의 메모"))
                        }
                        Button("기기의 사본을 다음 동기화에서 게시") { Task { _ = await team.resolvePersonal(conflict, keepLocal: true) } }
                        Button("서버의 사본 사용") { Task { _ = await team.resolvePersonal(conflict, keepLocal: false) } }
                    }
                }
                if team.conflicts.isEmpty { Text("확인할 개인 메모 충돌이 없어요.") }
            }.navigationTitle("개인 메모 충돌").toolbar { Button("닫기") { dismiss() } }
        }
    }
    private func inkPreview(_ snapshot: InkSnapshot, title: String) -> some View {
        VStack {
            Text(title).font(.caption)
            if let drawing = try? PKDrawing(data: snapshot.archive) {
                Image(uiImage: drawing.image(from: CGRect(x: 0, y: 0, width: snapshot.geometry.width, height: snapshot.geometry.height), scale: 0.4))
                    .resizable().scaledToFit().frame(maxHeight: 180).background(.white)
            }
        }
    }
}
