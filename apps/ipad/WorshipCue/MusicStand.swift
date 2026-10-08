import SwiftUI
import PDFKit
import PencilKit
import WorshipCueCore
import WorshipCueLocal

/// Fixed pigment values: chart ink must not adapt to the surrounding UI theme.
enum InkColor: String, CaseIterable, Identifiable {
    case black, blue, red, green, purple, orange, yellow, pink
    var id: String { rawValue }
    var uiColor: UIColor {
        let rgb: (CGFloat, CGFloat, CGFloat)
        switch self {
        case .black: rgb = (0, 0, 0)
        case .blue: rgb = (0.08, 0.32, 0.88)
        case .red: rgb = (0.86, 0.12, 0.18)
        case .green: rgb = (0.08, 0.60, 0.32)
        case .purple: rgb = (0.53, 0.22, 0.78)
        case .orange: rgb = (1, 0.48, 0.08)
        case .yellow: rgb = (1, 0.82, 0)
        case .pink: rgb = (0.96, 0.30, 0.60)
        }
        return UIColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
    }
    var name: String {
        switch self {
        case .black: return String(localized: "검정")
        case .blue: return String(localized: "파랑")
        case .red: return String(localized: "빨강")
        case .green: return String(localized: "초록")
        case .purple: return String(localized: "보라")
        case .orange: return String(localized: "주황")
        case .yellow: return String(localized: "노랑")
        case .pink: return String(localized: "분홍")
        }
    }
}

// PDFKit's Objective-C overlay protocol lacks actor annotations. Its UIKit callbacks
// keep the main-actor requirement, with runtime checking at the conformance boundary.
@MainActor final class MusicStand: NSObject, ObservableObject, @preconcurrency PDFPageOverlayViewProvider, PKCanvasViewDelegate {
    let pdfView = PDFView()
    let clipboard = InkClipboard()
    @Published private(set) var charts: [LocalChart] = []
    @Published private(set) var library: LibrarySnapshot = .empty
    @Published private(set) var preparationReport: String?
    @Published private(set) var current: LocalChart?
    @Published private(set) var pageIndex = 0
    @Published private(set) var pageCount = 0
    @Published private(set) var status = String(localized: "개인 메모 · Apple Pencil")
    @Published var error: String?
    @Published private(set) var busy = false
    @Published private(set) var selectionCount = 0
    @Published private(set) var transferMode: TransferOverlay.Mode = .inactive
    @Published private(set) var teamVisible = false
    @Published private(set) var fingerTesting = false
    @Published private(set) var selectedToolKind = 0
    @Published private(set) var penColor: InkColor = .black
    @Published private(set) var markerColor: InkColor = .yellow
    var selectedInkColor: InkColor { selectedToolKind == 1 ? markerColor : penColor }
    var currentLibraryVersion: LibraryVersion? { library.versions.first { $0.id == current?.id } }
    var currentSongTitle: String? { library.songs.first { $0.id == currentLibraryVersion?.songID }?.title }
    private let church = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let owner = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let occurrence = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    private var vault: DocumentVault?
    private var store: LocalInkStore?
    private var overlays: [ObjectIdentifier: PageInkView] = [:]
    private var pending: [InkAddress: InkSnapshot] = [:]
    private var latest: [InkAddress: InkSnapshot] = [:]
    private var debounce: Task<Void, Never>?
    private var tool: PKTool = PKInkingTool(.pen, color: .black, width: 2)
    private var teamIdentity: LayerIdentity?
    private var activeTools: Set<ObjectIdentifier> = []
    private var restoreFailures: Set<InkAddress> = []
    private var restoreReads: [InkAddress: Int] = [:]
    private var saveWrites: [InkAddress: Int] = [:]
    private var requestedPaste: (version: UUID, page: Int)?
    private let applicationSupport: URL?
    private var bookmarkPrefix: String { applicationSupport == nil ? "m0" : "m0.test.\(applicationSupport!.lastPathComponent)" }

    override convenience init() { self.init(applicationSupport: nil) }

    init(applicationSupport: URL?) {
        self.applicationSupport = applicationSupport
        super.init()
        penColor = UserDefaults.standard.string(forKey: "\(bookmarkPrefix).penColor").flatMap(InkColor.init(rawValue:)) ?? .black
        markerColor = UserDefaults.standard.string(forKey: "\(bookmarkPrefix).markerColor").flatMap(InkColor.init(rawValue:)) ?? .yellow
        tool = PKInkingTool(.pen, color: penColor.uiColor, width: 2)
        pdfView.displayMode = .singlePage
        pdfView.displayBox = .cropBox
        pdfView.autoScales = true
        pdfView.maxScaleFactor = 8
        pdfView.pageOverlayViewProvider = self
        // PDFKit only hit-tests page overlays in markup mode. The overlay still
        // passes finger gestures through to the PDF when Pencil-only is selected.
        pdfView.isInMarkupMode = true
        pdfView.backgroundColor = .secondarySystemBackground
        pdfView.accessibilityLabel = String(localized: "악보 · 페이지는 이 기기에서만 이동")
    }

    func start() async {
        guard current == nil, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let root = try applicationSupport ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: true).appendingPathComponent("WorshipCueM0")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            store = try LocalInkStore(url: root.appendingPathComponent("personal.sqlite"))
            let vault = try DocumentVault(root: root.appendingPathComponent("pdfs"))
            self.vault = vault
            let fixtures = ["song_A_v1_G", "song_A_v2_G", "song_A_v3_A", "geometry_rotations", "weekly_packet"]
            for (index, filename) in fixtures.enumerated() {
                guard let source = Bundle.main.url(forResource: filename, withExtension: "pdf", subdirectory: "pdfs"),
                      let id = UUID(uuidString: String(format: "10000000-0000-0000-0000-%012d", index + 1)) else {
                    throw VaultError.missingFixture
                }
                do { _ = try vault.importPDF(source, name: filename, fixtureID: id) }
                catch { self.error = String(localized: "일부 예시 파일을 열지 못했어요. 다른 저장된 악보를 선택할 수 있습니다.") }
            }
            charts = vault.charts
            try refreshLibrary()
            let remembered = UserDefaults.standard.string(forKey: "\(bookmarkPrefix).currentVersion")
            let preferred = charts.first(where: { $0.id.uuidString == remembered })
            if let chart = preferred ?? charts.first {
                do { try await open(chart, page: UserDefaults.standard.integer(forKey: "\(bookmarkPrefix).page")) }
                catch { fail(String(localized: "저장된 악보를 열지 못했어요. 악보 선택에서 다른 파일을 직접 선택해 주세요.")) }
            }
        } catch { fail(String(localized: "악보를 준비하지 못했어요. 저장된 파일은 유지됩니다.")) }
    }

    func choose(_ chart: LocalChart) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do { try await open(chart, page: 0) }
        catch { fail(String(localized: "악보를 열지 못했어요. 현재 악보와 메모는 유지됩니다.")) }
    }

    func importFile(_ url: URL) async {
        guard !busy, let vault else { return }
        busy = true; defer { busy = false }
        do {
            try beginTransition()
            defer { endTransition() }
            try await flush()
            let chart = try vault.importPDF(url, name: url.deletingPathExtension().lastPathComponent)
            charts = vault.charts
            try refreshLibrary()
            try await open(chart, page: 0)
        } catch { fail(String(localized: "PDF를 가져오지 못했어요. 현재 악보는 유지됩니다.")) }
    }

    private func open(_ chart: LocalChart, page: Int) async throws {
        guard let vault else { throw VaultError.invalidPDF }
        try beginTransition()
        defer { endTransition() }
        try await flush()
        let document = try vault.open(chart)
        let verifiedLibrary = try vault.library.snapshot()
        cancelTransfer()
        overlays.removeAll(); latest.removeAll(); restoreFailures.removeAll()
        current = chart; pageCount = document.pageCount
        pageIndex = min(max(0, page), document.pageCount - 1)
        teamIdentity = try LayerIdentity(churchID: church,
                                         versionID: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!, pageIndex: 0,
                                         scope: .team(performanceItemID: occurrence))
        pdfView.document = document
        if let target = document.page(at: pageIndex) { pdfView.go(to: target) }
        pdfView.autoScales = true
        library = verifiedLibrary
        remember()
    }

    func turnPage(_ delta: Int) async {
        guard !busy, let document = pdfView.document else { return }
        let target = pageIndex + delta
        guard target >= 0, target < pageCount, let page = document.page(at: target) else { return }
        busy = true; defer { busy = false }
        do {
            try beginTransition()
            defer { endTransition() }
            try await flush(); cancelTransfer()
            pageIndex = target; pdfView.go(to: page); remember()
        } catch { fail(String(localized: "메모를 저장하지 못했어요. 저장 후 페이지를 이동해 주세요.")) }
    }

    private func remember() {
        UserDefaults.standard.set(current?.id.uuidString, forKey: "\(bookmarkPrefix).currentVersion")
        UserDefaults.standard.set(pageIndex, forKey: "\(bookmarkPrefix).page")
        if let current, let vault {
            do { try vault.library.remember(versionID: current.id, pageIndex: pageIndex) }
            catch { fail(String(localized: "악보는 열렸지만 마지막 페이지를 기록하지 못했어요.")) }
        }
    }

    private func refreshLibrary() throws {
        guard let vault else { throw LibraryError.missingRecord }
        library = try vault.library.snapshot()
        charts = vault.charts
        preparationReport = nil
    }

    func openVersion(_ id: UUID, page: Int? = nil) async -> Bool {
        guard !busy, let vault, let chart = charts.first(where: { $0.id == id }) else { return false }
        busy = true; defer { busy = false }
        do {
            let destination = try page ?? vault.library.bookmark(versionID: id)
            try await open(chart, page: destination)
            try refreshLibrary()
            return true
        } catch { fail(String(localized: "악보를 열지 못했어요. 현재 악보와 메모는 유지됩니다.")); return false }
    }

    @discardableResult func updateSong(_ song: LibrarySong) -> Bool {
        do { guard let vault else { throw LibraryError.missingRecord }
            try vault.library.updateSong(song); try refreshLibrary(); return true
        } catch { self.error = String(localized: "곡 정보를 저장하지 못했어요. 제목과 찬송가 번호·판본을 확인해 주세요."); return false }
    }
    @discardableResult func prefer(_ version: LibraryVersion) -> Bool {
        do { guard let vault else { throw LibraryError.missingRecord }
            try vault.library.setPreferred(songID: version.songID, versionID: version.id); try refreshLibrary(); return true
        } catch { self.error = String(localized: "기본 악보를 저장하지 못했어요."); return false }
    }
    func saveSetlist(_ draft: LocalSetlist) -> LocalSetlist? {
        do { guard let vault else { throw LibraryError.missingRecord }
            let saved = try vault.library.saveSetlist(draft); try refreshLibrary(); return saved
        } catch LibraryError.staleSetlist {
            error = String(localized: "이 예배 목록이 변경되었어요. 닫은 뒤 다시 열어 확인해 주세요."); return nil
        } catch { self.error = String(localized: "예배 목록을 저장하지 못했어요. 악보와 키를 확인해 주세요."); return nil }
    }

    func importChart(_ url: URL, song: LibrarySong, label: String, writtenKey: String?) async -> Bool {
        guard !busy, let vault else { return false }
        busy = true; defer { busy = false }
        do {
            _ = try vault.importPDF(url, name: label, song: song, writtenKey: writtenKey)
            try refreshLibrary()
            return true // Importing or preferring a chart never navigates the current reader.
        } catch { self.error = String(localized: "PDF를 가져오지 못했어요. 파일·곡 제목·키와 저장 공간을 확인해 주세요."); return false }
    }
    func splitPacket(_ id: UUID, slices: [PacketSlice]) async -> Bool {
        guard !busy, let vault, let chart = charts.first(where: { $0.id == id }) else { return false }
        busy = true; defer { busy = false }
        do { _ = try vault.slicePacket(chart, slices: slices); try refreshLibrary(); return true }
        catch { self.error = String(localized: "주간 PDF를 나누지 못했어요. 페이지 범위·곡 제목·키와 저장 공간을 확인해 주세요."); return false }
    }

    func verifyVersion(_ id: UUID) -> Int? {
        guard !busy, let vault, let chart = charts.first(where: { $0.id == id }) else { return nil }
        do { let count = try vault.open(chart).pageCount; try refreshLibrary(); return count }
        catch { self.error = String(localized: "이 PDF를 확인하지 못했어요. 원본을 다시 가져와 주세요."); return nil }
    }

    /// Read-only previews never replace the reader or capture/change a note layer.
    func chartThumbnail(_ id: UUID, page: Int = 0) -> UIImage? {
        guard let vault, let chart = charts.first(where: { $0.id == id }) else { return nil }
        do {
            guard let source = try vault.open(chart).page(at: page) else { return nil }
            return source.thumbnail(of: CGSize(width: 120, height: 160), for: .cropBox)
        } catch { return nil } // The inspector reports an unavailable preview; opening remains verified separately.
    }

    /// Called only by the musician's explicit destination action; it previews and never commits ink.
    func requestPastePreview() {
        guard let current, clipboard.selection != nil else { return }
        if currentOverlay != nil { beginPaste() }
        else { requestedPaste = (current.id, pageIndex) }
    }

    func prepare(_ setlist: LocalSetlist) async {
        guard !busy, let vault else { return }
        busy = true; defer { busy = false }
        do {
            try beginTransition(); defer { endTransition() }
            try await flush()
            var required = Set(setlist.items.map(\.versionID))
            for item in setlist.items {
                if let preferred = library.preferences[item.songID] { required.insert(preferred) }
            }
            guard !required.isEmpty else { preparationReport = String(localized: "예배 목록에 곡을 먼저 추가해 주세요."); return }
            var verified = 0
            for id in required {
                guard let chart = charts.first(where: { $0.id == id }) else { continue }
                do { _ = try vault.open(chart); verified += 1 }
                catch { /* A failed checksum or missing file stays unready; readable chart is untouched. */ }
            }
            let report = verified == required.count
                ? String(localized: "오프라인 파일 확인 완료 · \(verified)개 악보. 선택 악보·개인 기본 악보·대기곡을 이 iPad에서 열 수 있습니다.")
                : String(localized: "오프라인 파일 \(verified) / \(required.count)개 확인 · 누락되거나 손상된 PDF를 다시 가져와 주세요.")
            try refreshLibrary(); preparationReport = report
        } catch { self.error = String(localized: "메모를 먼저 저장한 뒤 준비 상태를 다시 확인해 주세요.") }
    }

    func exportPDF(includePersonal: Bool) async -> URL? {
        guard !busy, let current, let vault, let store else { return nil }
        busy = true; defer { busy = false }
        do {
            try beginTransition(); defer { endTransition() }
            try await flush()
            guard restoreFailures.isEmpty else { throw InkStoreError.invalidRecord }
            let document = try vault.open(current)
            var drawings: [Int: PKDrawing] = [:]
            if includePersonal {
                for index in 0..<document.pageCount {
                    let address = try InkAddress(churchID: church, ownerID: owner, versionID: current.id, pageIndex: index)
                    if let saved = try await store.load(address) {
                        guard let page = document.page(at: index), saved.geometry == (try page.canonicalGeometry()) else {
                            throw InkStoreError.geometryMismatch
                        }
                        drawings[index] = try PKDrawing(data: saved.archive)
                    }
                }
            }
            let cache = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("WorshipCueExports").appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            let output = cache.appendingPathComponent("WorshipCue.pdf")
            try PDFExporter.write(document, drawings: drawings, to: output)
            return output
        } catch { self.error = String(localized: "PDF를 내보내지 못했어요. 메모 복원 상태와 저장 공간을 확인해 주세요."); return nil }
    }

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        let key = ObjectIdentifier(page)
        if let existing = overlays[key] { return existing }
        guard let current, let document = view.document, let store else { return nil }
        do {
            let index = document.index(for: page)
            guard index != NSNotFound else { return nil }
            let address = try InkAddress(churchID: church, ownerID: owner, versionID: current.id, pageIndex: index)
            let geometry = try page.canonicalGeometry()
            let overlay = PageInkView(address: address, geometry: geometry, pdfView: view, page: page)
            overlay.personal.delegate = self; overlay.personal.tool = tool
            overlay.fingerTesting = fingerTesting
            overlay.personal.drawingPolicy = fingerTesting ? .anyInput : .pencilOnly
            overlays[key] = overlay
            overlay.onProgrammaticChange = { [weak self, weak overlay] in
                guard let self, let overlay else { return }
                self.capture(overlay)
            }
            // Capture IDs, never use the newly selected chart in a delayed restore/save.
            Task { [weak self, weak overlay] in
                guard let self, let overlay else { return }
                await self.restore(overlay, key: key, store: store)
            }
            return overlay
        } catch { fail(String(localized: "페이지 좌표를 확인하지 못했어요.")); return nil }
    }

    private func restore(_ overlay: PageInkView, key: ObjectIdentifier, store: LocalInkStore) async {
        let address = overlay.address
        restoreReads[address, default: 0] += 1
        defer {
            restoreReads[address, default: 1] -= 1
            if restoreReads[address] == 0 { restoreReads.removeValue(forKey: address) }
            pruneRecent(address)
        }
        do {
            let saved = try await store.load(address)
            guard overlays[key] === overlay else { return }
            let snapshot = try InkSnapshot.restoreCandidate(durable: saved, recent: latest[address], pending: pending[address])
            if let snapshot, snapshot.geometry != overlay.geometry { throw InkStoreError.geometryMismatch }
            let drawing = try snapshot.map { try PKDrawing(data: $0.archive) } ?? PKDrawing()
            overlay.restore(drawing, generation: snapshot?.generation ?? 0)
            overlay.personal.isUserInteractionEnabled = !busy
            if let snapshot { latest[address] = snapshot }
            restoreFailures.remove(address)
            applyTeam(to: overlay)
            if requestedPaste?.version == address.versionID, requestedPaste?.page == address.pageIndex {
                requestedPaste = nil
                beginPaste()
            }
        } catch {
            guard overlays[key] === overlay else { return }
            restoreFailures.insert(address)
            fail(String(localized: "메모를 복원하지 못했어요. 이 페이지의 필기는 잠시 멈춥니다."))
        }
    }

    private func pruneRecent(_ address: InkAddress) {
        guard pending[address] == nil, restoreReads[address] == nil, saveWrites[address] == nil,
              !overlays.values.contains(where: { $0.address == address }) else { return }
        latest.removeValue(forKey: address)
    }

    private func beginTransition() throws {
        guard activeTools.isEmpty else {
            fail(String(localized: "필기를 마친 후 다시 이동해 주세요."))
            throw InkStoreError.invalidRecord
        }
        for overlay in overlays.values {
            overlay.personal.isUserInteractionEnabled = false
            capture(overlay)
        }
    }
    private func endTransition() {
        for overlay in overlays.values { overlay.personal.isUserInteractionEnabled = overlay.ready }
    }

    func pdfView(_ pdfView: PDFView, willDisplayOverlayView overlayView: UIView, for page: PDFPage) {
        (overlayView as? PageInkView)?.alignToPDF()
    }
    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        guard let overlay = overlayView as? PageInkView else { return }
        capture(overlay)
        activeTools.remove(ObjectIdentifier(overlay.personal))
        scheduleSave()
        overlays.removeValue(forKey: ObjectIdentifier(page))
        overlay.personal.delegate = nil
        overlay.onProgrammaticChange = nil
        pruneRecent(overlay.address)
    }

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        activeTools.insert(ObjectIdentifier(canvasView))
        debounce?.cancel(); debounce = nil
        status = String(localized: "필기 중…")
    }
    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        activeTools.remove(ObjectIdentifier(canvasView))
        if let overlay = overlays.values.first(where: { $0.personal === canvasView }) { capture(overlay) }
        scheduleSave()
    }
    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard let overlay = overlays.values.first(where: { $0.personal === canvasView }),
              overlay.ready, !overlay.applyingDrawing else { return }
        capture(overlay)
    }

    private func capture(_ overlay: PageInkView) {
        guard overlay.ready else { return }
        overlay.updateAccessibility()
        let archive = overlay.personal.drawing.dataRepresentation()
        guard archive != overlay.lastCapturedArchive else { return }
        overlay.lastCapturedArchive = archive
        overlay.generation += 1
        pending[overlay.address] = InkSnapshot(address: overlay.address, geometry: overlay.geometry,
                                              generation: overlay.generation, archive: archive)
        latest[overlay.address] = pending[overlay.address]
        status = String(localized: "저장 중…")
        scheduleSave()
    }

    private func scheduleSave() {
        guard activeTools.isEmpty, !pending.isEmpty else { return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { return }
            guard let self, self.activeTools.isEmpty else { return }
            do { try await self.flush(onlyAfterPenUp: true) }
            catch { self.fail(String(localized: "기기에 저장하지 못했어요. 메모를 유지하고 다시 시도합니다.")) }
        }
    }

    func flush(onlyAfterPenUp: Bool = false) async throws {
        debounce?.cancel(); debounce = nil
        guard let store else {
            if pending.isEmpty { return }; throw InkStoreError.invalidRecord
        }
        // Main actor remains responsive; immutable bytes/identity cross into the store actor.
        while !pending.isEmpty {
            if onlyAfterPenUp, !activeTools.isEmpty { return }
            let snapshots = Array(pending.values)
            for snapshot in snapshots {
                if onlyAfterPenUp, !activeTools.isEmpty { return }
                saveWrites[snapshot.address, default: 0] += 1
                defer {
                    saveWrites[snapshot.address, default: 1] -= 1
                    if saveWrites[snapshot.address] == 0 { saveWrites.removeValue(forKey: snapshot.address) }
                    pruneRecent(snapshot.address)
                }
                do { try await store.save(snapshot) }
                catch InkStoreError.staleGeneration {
                    guard let durable = try await store.load(snapshot.address),
                          durable.generation > snapshot.generation,
                          latest[snapshot.address] == durable else { throw InkStoreError.staleGeneration }
                }
                if pending[snapshot.address]?.generation == snapshot.generation { pending.removeValue(forKey: snapshot.address) }
                pruneRecent(snapshot.address)
            }
        }
        if !restoreFailures.isEmpty { status = String(localized: "메모 복원 확인 필요") }
        else { status = activeTools.isEmpty ? String(localized: "기기에 저장됨") : String(localized: "필기 중…") }
    }

    func retrySave() async {
        if current == nil { await start(); return }
        if let store {
            for (key, overlay) in overlays where restoreFailures.contains(overlay.address) {
                await restore(overlay, key: key, store: store)
            }
        }
        do {
            try await flush()
            if restoreFailures.isEmpty { error = nil }
        }
        catch { fail(String(localized: "기기에 저장하지 못했어요. 남은 저장 공간을 확인해 주세요.")) }
    }
    private func fail(_ message: String) { error = message; status = String(localized: "저장 또는 복원 확인 필요") }

    var currentOverlay: PageInkView? {
        overlays.values.first { $0.address.versionID == current?.id && $0.address.pageIndex == pageIndex && $0.ready }
    }
    func setTool(_ kind: Int) {
        cancelTransfer()
        selectedToolKind = (0...2).contains(kind) ? kind : 0
        applyTool()
    }
    func setInkColor(_ color: InkColor) {
        guard selectedToolKind != 2 else { return }
        if selectedToolKind == 1 {
            markerColor = color
            UserDefaults.standard.set(color.rawValue, forKey: "\(bookmarkPrefix).markerColor")
        } else {
            penColor = color
            UserDefaults.standard.set(color.rawValue, forKey: "\(bookmarkPrefix).penColor")
        }
        applyTool()
    }
    private func applyTool() {
        switch selectedToolKind {
        case 1: tool = PKInkingTool(.marker, color: markerColor.uiColor, width: 18)
        case 2: tool = PKEraserTool(.vector)
        default: tool = PKInkingTool(.pen, color: penColor.uiColor, width: 2)
        }
        for overlay in overlays.values { overlay.personal.tool = tool }
    }
    func undo() { cancelTransfer(); currentOverlay?.personal.undoManager?.undo() }
    func redo() { cancelTransfer(); currentOverlay?.personal.undoManager?.redo() }
    func setFingerTesting(_ value: Bool) {
        fingerTesting = value
        for overlay in overlays.values {
            overlay.fingerTesting = value; overlay.personal.drawingPolicy = value ? .anyInput : .pencilOnly
        }
    }
    func showTeam(_ value: Bool) {
        teamVisible = value
        for overlay in overlays.values { applyTeam(to: overlay) }
    }
    private func applyTeam(to overlay: PageInkView) {
        guard teamVisible, let teamIdentity,
              teamIdentity.mayOverlayTeam(on: overlay.address.versionID, performanceItem: occurrence,
                                          church: overlay.address.churchID, page: overlay.address.pageIndex) else {
            overlay.team.image = nil; overlay.team.isHidden = true; return
        }
        overlay.team.image = Self.sampleTeamDrawing().image(from: overlay.team.bounds, scale: 2)
        overlay.team.isHidden = false
    }
    static func sampleTeamDrawing() -> PKDrawing {
        let points = (0...40).map { index -> PKStrokePoint in
            let angle = CGFloat(index) / 40 * .pi * 2
            return PKStrokePoint(location: CGPoint(x: 200 + cos(angle) * 65, y: 220 + sin(angle) * 25),
                                 timeOffset: Double(index) * 0.01, size: CGSize(width: 3, height: 3),
                                 opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .systemRed),
                                           path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 0)))])
    }

    func beginSelection() {
        guard let overlay = currentOverlay else { return }
        transferMode = .select; selectionCount = 0
        overlay.transfer.mode = .select; overlay.transfer.selection = .zero; overlay.transfer.selectedBounds = []; overlay.transfer.preview = nil
        overlay.transfer.onChange = { [weak self, weak overlay] in
            guard let self, let overlay else { return }
            let selected = overlay.personal.drawing.strokes.filter { $0.renderBounds.intersects(overlay.transfer.selection) }
            self.selectionCount = selected.count
            overlay.transfer.selectedBounds = selected.map { $0.renderBounds }
            overlay.transfer.preview = PKDrawing(strokes: selected)
        }
    }
    func copySelection() {
        guard let overlay = currentOverlay, transferMode == .select else { return }
        selectionCount = clipboard.copy(from: overlay.personal.drawing, address: overlay.address,
                                         geometry: overlay.geometry, rectangle: overlay.transfer.selection)
        cancelTransfer()
    }
    func beginPaste() {
        guard let overlay = currentOverlay, clipboard.selection != nil else { return }
        transferMode = .paste; overlay.transfer.mode = .paste
        let visible = overlay.personal.convert(pdfView.bounds, from: pdfView).intersection(overlay.personal.bounds)
        let region = visible.isNull || visible.isEmpty ? overlay.personal.bounds : visible
        overlay.transfer.centerPoint = CGPoint(x: region.midX, y: region.midY)
        if let selection = clipboard.selection {
            overlay.transfer.scale = min(1, region.width * 0.8 / max(1, selection.bounds.width),
                                          region.height * 0.8 / max(1, selection.bounds.height))
        }
        overlay.transfer.onChange = { [weak self, weak overlay] in
            guard let self, let overlay else { return }
            overlay.transfer.preview = self.clipboard.placed(at: overlay.transfer.centerPoint, scale: overlay.transfer.scale)
        }
        overlay.transfer.onChange?(); overlay.transfer.setNeedsDisplay()
    }
    func scalePaste(_ value: CGFloat) {
        guard let overlay = currentOverlay, transferMode == .paste else { return }
        overlay.transfer.scale = min(4, max(0.25, overlay.transfer.scale * value))
        overlay.transfer.onChange?(); overlay.transfer.setNeedsDisplay()
    }
    func commitPaste() {
        guard let overlay = currentOverlay, transferMode == .paste, let preview = overlay.transfer.preview else { return }
        overlay.replaceWithUndo(PKDrawing(strokes: overlay.personal.drawing.strokes + preview.strokes))
        cancelTransfer()
    }
    func cancelTransfer() {
        requestedPaste = nil
        transferMode = .inactive
        for overlay in overlays.values { overlay.transfer.mode = .inactive; overlay.transfer.preview = nil; overlay.transfer.onChange = nil }
    }
}

struct PDFStandView: UIViewRepresentable {
    let stand: MusicStand
    func makeUIView(context: Context) -> PDFStandContainer { PDFStandContainer(stand: stand) }
    func updateUIView(_ uiView: PDFStandContainer, context: Context) {}
}

/// PDFKit supplies its own accessibility tree and omits page-overlay subviews.
/// Keep its readable PDF text, then expose the app-owned, currently visible layers.
@MainActor final class PDFStandContainer: UIView {
    private weak var stand: MusicStand?

    init(stand: MusicStand) {
        self.stand = stand
        super.init(frame: .zero)
        addSubview(stand.pdfView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        stand?.pdfView.frame = bounds
    }

    override var accessibilityElements: [Any]? {
        get {
            guard let stand else { return [] }
            var elements: [Any] = [stand.pdfView]
            if let overlay = stand.currentOverlay, overlay.window != nil {
                if !overlay.team.isHidden { elements.append(overlay.team) }
                elements.append(overlay.personal)
                if overlay.transfer.mode != .inactive { elements.append(overlay.transfer) }
            }
            return elements
        }
        set { super.accessibilityElements = newValue }
    }
}
